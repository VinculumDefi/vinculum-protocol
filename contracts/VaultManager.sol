// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// VaultManager.sol
// Commitment vault engine for Vinculum Protocol
//
// Architecture decisions locked:
//   - Atomic 3-bucket treasury split on every deposit:
//       82% → Core Reserve Pool
//       12% → Dev Fund (founder-controlled, permanent)
//        6% → Ecosystem Growth Fund
//   - Emergency pause: deposits only, withdrawals NEVER blocked
//   - AssetRegistry wired for price + quality data
//   - Trial vault: 7-day, 2.5% retained, test-before-commit flow
//   - Standard vaults: 30/90/180/365/730 days, 5% retained
//   - VCLM mint formula: deposit × price × quality × commitment × emission
//   - Emission decay: 1.667% per month (~20%/year), 10% floor
//   - Per-asset deposit caps (governance-settable)
//   - Native ETH supported via WETH wrapper
// ─────────────────────────────────────────────────────────────────────────────

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IVinculumToken {
    function mint(address to, uint256 amount) external;
    function depositsPaused() external view returns (bool);
}

interface IAssetRegistry {
    function getPrice(address asset) external view returns (uint256 price);
    function getQualityMultiplierBps(address asset) external view returns (uint256 bps);
    function isApproved(address asset) external view returns (bool);
}

interface IWETH {
    function deposit()  external payable;
    function withdraw(uint256 amount) external;
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract VaultManager is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── ROLES ────────────────────────────────────────────────────────────────
    bytes32 public constant ASSET_MANAGER_ROLE    = keccak256("ASSET_MANAGER_ROLE");
    bytes32 public constant EMISSION_MANAGER_ROLE = keccak256("EMISSION_MANAGER_ROLE");

    // ── TREASURY SPLIT ───────────────────────────────────────────────────────
    // Atomic split on every deposit retention. Immutable percentages.
    // Dev Fund address is founder-controlled permanently.
    uint256 public constant CORE_RESERVE_BPS  = 8_200; // 82%
    uint256 public constant DEV_FUND_BPS      = 1_200; // 12%
    uint256 public constant ECOSYSTEM_BPS     =   600; //  6%
    uint256 public constant BPS_DENOMINATOR   = 10_000;

    // Treasury pool addresses — set at deployment, immutable
    address public immutable coreReservePool;
    address public immutable devFund;
    address public immutable ecosystemFund;

    // ── PROTOCOL RETENTION RATE ───────────────────────────────────────────────
    uint256 public constant STANDARD_RETENTION_BPS = 500;  // 5%
    uint256 public constant TRIAL_RETENTION_BPS    = 250;  // 2.5% per phase

    // ── VAULT TYPES ──────────────────────────────────────────────────────────
    enum VaultType {
        Trial,    // 7-day trial
        Days30,   // 30-day
        Days90,   // 90-day
        Days180,  // 180-day
        Days365,  // 1-year
        Days730   // 2-year
    }

    // Lock durations in seconds
    mapping(VaultType => uint256) public lockDurations;

    // Commitment multipliers in BPS (10000 = 1.0×)
    mapping(VaultType => uint256) public commitmentMultipliers;

    // ── VAULT STATUS ─────────────────────────────────────────────────────────
    enum VaultStatus {
        Trial,      // 7-day trial active
        Active,     // committed vault, lock in progress
        Matured,    // lock period ended, awaiting withdrawal
        Withdrawn,  // principal returned, vault closed
        Continued   // trial converted to 30-day vault
    }

    // ── VAULT STRUCT ─────────────────────────────────────────────────────────
    struct VaultEntry {
        uint256    vaultId;
        address    owner;
        address    asset;
        VaultType  vaultType;
        VaultStatus status;
        uint256    grossDeposit;    // original deposit amount
        uint256    retainedAmount;  // amount kept by protocol (5% or 2.5%)
        uint256    principal;       // amount returnable to user (95% or 97.5%)
        uint256    vclmMinted;      // VCLM earned at vault entry
        uint256    openedAt;        // block.timestamp at vault open
        uint256    maturesAt;       // block.timestamp when withdrawable
        bool       isETH;           // true if deposited as native ETH (via WETH)
    }

    // ── EMISSION PARAMETERS ──────────────────────────────────────────────────
    // Base emission: $0.10 = 1 VCLM at launch
    // Meaning: 10 VCLM per $1 USD of committed value
    uint256 public constant BASE_EMISSION_RATE = 10 * 1e18; // 10 VCLM per $1 (18 dec)

    // Decay: 1.667% per month ≈ 20% per year
    // Stored as monthly decay BPS: 167 BPS = 1.67%
    uint256 public constant MONTHLY_DECAY_BPS  = 167;

    // Emission floor: 10% of base rate
    uint256 public constant EMISSION_FLOOR_BPS = 1_000; // 10% of base

    // Deployment timestamp — decay calculated from this point
    uint256 public immutable deployedAt;

    // ── STORAGE ──────────────────────────────────────────────────────────────
    IVinculumToken public immutable vclmToken;
    IAssetRegistry public           assetRegistry;
    address        public immutable weth;

    uint256 public vaultCount;
    mapping(uint256 => VaultEntry) public vaults;

    // owner => list of vault IDs
    mapping(address => uint256[]) public ownerVaults;

    // asset => total currently deposited (for deposit cap checks)
    mapping(address => uint256) public totalDepositedByAsset;

    // asset => maximum total deposit allowed (0 = no cap)
    // Governance-settable via ASSET_MANAGER_ROLE
    mapping(address => uint256) public depositCapByAsset;

    // ── EVENTS ───────────────────────────────────────────────────────────────
    event TrialEntered(
        uint256 indexed vaultId,
        address indexed owner,
        address indexed asset,
        uint256         grossDeposit,
        uint256         retained,
        uint256         principal,
        uint256         vclmMinted
    );
    event TrialExited(
        uint256 indexed vaultId,
        address indexed owner,
        uint256         principalReturned
    );
    event TrialContinued(
        uint256 indexed vaultId,
        address indexed owner,
        uint256         additionalRetained,
        uint256         additionalVclm
    );
    event VaultOpened(
        uint256 indexed vaultId,
        address indexed owner,
        address indexed asset,
        VaultType       vaultType,
        uint256         grossDeposit,
        uint256         retained,
        uint256         principal,
        uint256         vclmMinted,
        uint256         maturesAt
    );
    event VaultWithdrawn(
        uint256 indexed vaultId,
        address indexed owner,
        uint256         principalReturned
    );
    event TreasurySplit(
        address indexed asset,
        uint256         totalRetained,
        uint256         coreReserve,
        uint256         devFundAmount,
        uint256         ecosystemAmount
    );
    event DepositCapUpdated(
        address indexed asset,
        uint256         newCap
    );
    event AssetRegistryUpdated(address indexed newRegistry);

    // ── CONSTRUCTOR ──────────────────────────────────────────────────────────
    /**
     * @param _vclmToken       Address of VinculumToken contract
     * @param _coreReservePool Address of Core Reserve Pool (82% of retention)
     * @param _devFund         Address of Dev Fund (12% — founder-controlled)
     * @param _ecosystemFund   Address of Ecosystem Growth Fund (6%)
     * @param _weth            Address of WETH contract on Base
     *                         Base mainnet WETH: 0x4200000000000000000000000000000000000006
     * @param admin            DEFAULT_ADMIN_ROLE holder (founder multisig)
     */
    constructor(
        address _vclmToken,
        address _coreReservePool,
        address _devFund,
        address _ecosystemFund,
        address _weth,
        address admin
    ) {
        require(_vclmToken       != address(0), "VM: invalid token");
        require(_coreReservePool != address(0), "VM: invalid core reserve");
        require(_devFund         != address(0), "VM: invalid dev fund");
        require(_ecosystemFund   != address(0), "VM: invalid ecosystem fund");
        require(_weth            != address(0), "VM: invalid WETH");
        require(admin            != address(0), "VM: invalid admin");

        vclmToken       = IVinculumToken(_vclmToken);
        coreReservePool = _coreReservePool;
        devFund         = _devFund;
        ecosystemFund   = _ecosystemFund;
        weth            = _weth;
        deployedAt      = block.timestamp;

        _grantRole(DEFAULT_ADMIN_ROLE,    admin);
        _grantRole(ASSET_MANAGER_ROLE,    admin);
        _grantRole(EMISSION_MANAGER_ROLE, admin);

        // Lock durations
        lockDurations[VaultType.Trial]   = 7   days;
        lockDurations[VaultType.Days30]  = 30  days;
        lockDurations[VaultType.Days90]  = 90  days;
        lockDurations[VaultType.Days180] = 180 days;
        lockDurations[VaultType.Days365] = 365 days;
        lockDurations[VaultType.Days730] = 730 days;

        // Commitment multipliers in BPS
        commitmentMultipliers[VaultType.Trial]   = 10_000; // 1.0×
        commitmentMultipliers[VaultType.Days30]  = 10_000; // 1.0×
        commitmentMultipliers[VaultType.Days90]  = 12_500; // 1.25×
        commitmentMultipliers[VaultType.Days180] = 15_000; // 1.5×
        commitmentMultipliers[VaultType.Days365] = 20_000; // 2.0×
        commitmentMultipliers[VaultType.Days730] = 30_000; // 3.0×
    }

    // ── ASSET REGISTRY WIRING ────────────────────────────────────────────────

    /**
     * @dev Sets the AssetRegistry contract.
     *      Can only be set once after deployment.
     * @param _assetRegistry Address of AssetRegistry contract
     */
    function setAssetRegistry(address _assetRegistry)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_assetRegistry != address(0),       "VM: invalid registry");
        require(address(assetRegistry) == address(0), "VM: registry already set");
        assetRegistry = IAssetRegistry(_assetRegistry);
        emit AssetRegistryUpdated(_assetRegistry);
    }

    // ── TRIAL VAULT ──────────────────────────────────────────────────────────

    /**
     * @dev Opens a 7-day trial vault.
     *      2.5% retained at entry, split atomically across three treasury pools.
     *      7/30 of the 30-day VCLM reward minted immediately to the user.
     *      After 7 days: user can exit (return 97.5%) or continue (convert to 30-day).
     *
     * @param asset   ERC-20 token address to deposit
     * @param amount  Gross deposit amount (before 2.5% retention)
     * @return vaultId  The ID of the newly created trial vault
     */
    function enterTrial(address asset, uint256 amount)
        external
        nonReentrant
        returns (uint256 vaultId)
    {
        require(!vclmToken.depositsPaused(),          "VM: deposits paused");
        require(address(assetRegistry) != address(0), "VM: registry not set");
        require(assetRegistry.isApproved(asset),      "VM: asset not approved");
        require(amount > 0,                           "VM: amount must be > 0");

        _checkDepositCap(asset, amount);

        // Pull deposit
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        // Calculate retention: 2.5%
        uint256 retained  = (amount * TRIAL_RETENTION_BPS) / BPS_DENOMINATOR;
        uint256 principal = amount - retained;

        // Atomic treasury split
        _splitToTreasury(asset, retained);

        // Mint VCLM: 7/30 of what a 30-day vault would earn
        uint256 fullReward   = _computeVCLM(amount, asset, VaultType.Days30);
        uint256 trialReward  = (fullReward * 7) / 30;
        vclmToken.mint(msg.sender, trialReward);

        // Record vault
        vaultId = _createVault(
            msg.sender,
            asset,
            VaultType.Trial,
            VaultStatus.Trial,
            amount,
            retained,
            principal,
            trialReward,
            false
        );

        totalDepositedByAsset[asset] += principal;

        emit TrialEntered(vaultId, msg.sender, asset, amount, retained, principal, trialReward);
    }

    /**
     * @dev Exits a trial vault after the 7-day period.
     *      Returns 97.5% of original deposit.
     *      VCLM already minted is kept — no clawback.
     *
     * @param vaultId  ID of the trial vault to exit
     */
    function exitTrial(uint256 vaultId) external nonReentrant {
        VaultEntry storage vault = vaults[vaultId];
        _requireVaultOwner(vault);
        require(vault.status   == VaultStatus.Trial,           "VM: not a trial vault");
        require(block.timestamp >= vault.openedAt + lockDurations[VaultType.Trial],
                                                               "VM: trial period not ended");

        vault.status = VaultStatus.Withdrawn;
        totalDepositedByAsset[vault.asset] -= vault.principal;

        _returnPrincipal(vault);

        emit TrialExited(vaultId, msg.sender, vault.principal);
    }

    /**
     * @dev Continues a trial vault, converting it to a full 30-day vault.
     *      Additional 2.5% retained (total 5% across both phases).
     *      Remaining 23/30 of the 30-day VCLM reward minted to user.
     *      Lock period resets to 30 days from continuation timestamp.
     *
     * @param vaultId  ID of the trial vault to continue
     */
    function continueTrial(uint256 vaultId) external nonReentrant {
        require(!vclmToken.depositsPaused(), "VM: deposits paused");

        VaultEntry storage vault = vaults[vaultId];
        _requireVaultOwner(vault);
        require(vault.status   == VaultStatus.Trial,           "VM: not a trial vault");
        require(block.timestamp >= vault.openedAt + lockDurations[VaultType.Trial],
                                                               "VM: trial period not ended");

        // Additional 2.5% retention from principal
        uint256 additionalRetained = (vault.grossDeposit * TRIAL_RETENTION_BPS) / BPS_DENOMINATOR;
        require(vault.principal >= additionalRetained, "VM: insufficient principal");

        // Atomic treasury split for additional retention
        // Note: retained amount is already held in contract from trial entry
        _splitToTreasury(vault.asset, additionalRetained);

        vault.retainedAmount += additionalRetained;
        vault.principal      -= additionalRetained;

        // Mint remaining 23/30 of 30-day reward
        uint256 fullReward         = _computeVCLM(vault.grossDeposit, vault.asset, VaultType.Days30);
        uint256 additionalReward   = (fullReward * 23) / 30;
        vclmToken.mint(msg.sender, additionalReward);
        vault.vclmMinted += additionalReward;

        // Convert to 30-day vault
        vault.status    = VaultStatus.Active;
        vault.vaultType = VaultType.Days30;
        vault.maturesAt = block.timestamp + lockDurations[VaultType.Days30];

        emit TrialContinued(vaultId, msg.sender, additionalRetained, additionalReward);
    }

    // ── STANDARD VAULT ───────────────────────────────────────────────────────

    /**
     * @dev Opens a standard commitment vault.
     *      5% retained atomically across three treasury pools.
     *      Full VCLM reward minted immediately to user.
     *      Principal locked until maturity.
     *
     * @param asset      ERC-20 token address (use address(0) for native ETH)
     * @param amount     Gross deposit amount (before 5% retention)
     *                   For ETH: must equal msg.value
     * @param vaultType  VaultType.Days30 through VaultType.Days730
     * @return vaultId   The ID of the newly created vault
     */
    function openVault(
        address   asset,
        uint256   amount,
        VaultType vaultType
    )
        external
        payable
        nonReentrant
        returns (uint256 vaultId)
    {
        require(!vclmToken.depositsPaused(),          "VM: deposits paused");
        require(address(assetRegistry) != address(0), "VM: registry not set");
        require(amount > 0,                           "VM: amount must be > 0");
        require(
            vaultType == VaultType.Days30  ||
            vaultType == VaultType.Days90  ||
            vaultType == VaultType.Days180 ||
            vaultType == VaultType.Days365 ||
            vaultType == VaultType.Days730,
            "VM: invalid vault type for openVault"
        );

        bool isETH = (asset == address(0));
        address effectiveAsset = isETH ? weth : asset;

        require(assetRegistry.isApproved(effectiveAsset), "VM: asset not approved");
        _checkDepositCap(effectiveAsset, amount);

        if (isETH) {
            // Native ETH path — wrap to WETH
            require(msg.value == amount, "VM: ETH amount mismatch");
            IWETH(weth).deposit{value: msg.value}();
        } else {
            require(msg.value == 0, "VM: ETH not expected for ERC20 vault");
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        }

        // Calculate retention: 5%
        uint256 retained  = (amount * STANDARD_RETENTION_BPS) / BPS_DENOMINATOR;
        uint256 principal = amount - retained;

        // Atomic treasury split
        _splitToTreasury(effectiveAsset, retained);

        // Mint full VCLM reward
        uint256 vclmAmount = _computeVCLM(amount, effectiveAsset, vaultType);
        vclmToken.mint(msg.sender, vclmAmount);

        uint256 maturesAt = block.timestamp + lockDurations[vaultType];

        // Record vault
        vaultId = _createVault(
            msg.sender,
            effectiveAsset,
            vaultType,
            VaultStatus.Active,
            amount,
            retained,
            principal,
            vclmAmount,
            isETH
        );

        vaults[vaultId].maturesAt = maturesAt;
        totalDepositedByAsset[effectiveAsset] += principal;

        emit VaultOpened(
            vaultId, msg.sender, effectiveAsset,
            vaultType, amount, retained, principal, vclmAmount, maturesAt
        );
    }

    /**
     * @dev Withdraws principal from a matured vault.
     *      Returns 95% of original deposit (5% retention is permanent).
     *      NEVER blocked by pause — withdrawals always work.
     *
     * @param vaultId  ID of the vault to withdraw from
     */
    function withdrawMatured(uint256 vaultId) external nonReentrant {
        VaultEntry storage vault = vaults[vaultId];
        _requireVaultOwner(vault);
        require(
            vault.status == VaultStatus.Active ||
            vault.status == VaultStatus.Matured,
            "VM: vault not withdrawable"
        );
        require(block.timestamp >= vault.maturesAt, "VM: vault not matured");

        vault.status = VaultStatus.Withdrawn;
        totalDepositedByAsset[vault.asset] -= vault.principal;

        _returnPrincipal(vault);

        emit VaultWithdrawn(vaultId, msg.sender, vault.principal);
    }

    // ── VCLM MINT FORMULA ────────────────────────────────────────────────────

    /**
     * @dev Preview VCLM reward before depositing.
     *      Read-only. No state changes.
     *
     * @param asset      Token address
     * @param amount     Gross deposit amount
     * @param vaultType  Vault duration
     * @return vclmAmount  Estimated VCLM to be minted
     */
    function previewMint(
        address   asset,
        uint256   amount,
        VaultType vaultType
    ) external view returns (uint256 vclmAmount) {
        address effectiveAsset = (asset == address(0)) ? weth : asset;
        return _computeVCLM(amount, effectiveAsset, vaultType);
    }

    /**
     * @dev Returns the current emission factor (VCLM per $1 USD).
     *      Decays 1.667% per month from launch.
     *      Floored at 10% of base rate.
     *
     * @return factor  Current emission rate (18 decimals)
     */
    function currentEmissionFactor() public view returns (uint256 factor) {
        // Calculate months elapsed since deployment
        uint256 monthsElapsed = (block.timestamp - deployedAt) / 30 days;

        // Apply monthly decay: factor = BASE × (1 - 0.01667)^months
        // Approximated iteratively to avoid floating point
        factor = BASE_EMISSION_RATE;
        for (uint256 i = 0; i < monthsElapsed; i++) {
            factor = factor - (factor * MONTHLY_DECAY_BPS) / BPS_DENOMINATOR;
        }

        // Apply floor: minimum 10% of base rate
        uint256 floor = (BASE_EMISSION_RATE * EMISSION_FLOOR_BPS) / BPS_DENOMINATOR;
        if (factor < floor) factor = floor;
    }

    // ── DEPOSIT CAP MANAGEMENT ───────────────────────────────────────────────

    /**
     * @dev Sets a deposit cap for a specific asset.
     *      0 = no cap.
     *      Called by ASSET_MANAGER_ROLE (governance after Milestone 2).
     *
     * @param asset  Token address
     * @param cap    Maximum total deposit in asset units (0 = unlimited)
     */
    function setDepositCap(address asset, uint256 cap)
        external
        onlyRole(ASSET_MANAGER_ROLE)
    {
        depositCapByAsset[asset] = cap;
        emit DepositCapUpdated(asset, cap);
    }

    // ── VIEW HELPERS ─────────────────────────────────────────────────────────

    /**
     * @dev Returns full vault details.
     */
    function getVault(uint256 vaultId)
        external
        view
        returns (VaultEntry memory)
    {
        return vaults[vaultId];
    }

    /**
     * @dev Returns all vault IDs for an owner.
     */
    function getOwnerVaults(address owner)
        external
        view
        returns (uint256[] memory)
    {
        return ownerVaults[owner];
    }

    /**
     * @dev Returns total deposited for an asset vs its cap.
     */
    function getAssetDepositInfo(address asset)
        external
        view
        returns (uint256 totalDeposited, uint256 cap)
    {
        return (totalDepositedByAsset[asset], depositCapByAsset[asset]);
    }

    // ── INTERNAL HELPERS ─────────────────────────────────────────────────────

    /**
     * @dev Core VCLM mint calculation.
     *      Formula: deposit × price × qualityMultiplier × commitmentMultiplier × emissionFactor
     *
     *      All values in 18 decimals.
     *      Result is VCLM amount to mint.
     */
    function _computeVCLM(
        uint256   amount,
        address   asset,
        VaultType vaultType
    ) internal view returns (uint256) {
        // USD value of deposit (18 decimals)
        uint256 price      = assetRegistry.getPrice(asset);
        uint256 usdValue   = (amount * price) / 1e18;

        // Quality multiplier from asset tier (BPS)
        uint256 qualityBps = assetRegistry.getQualityMultiplierBps(asset);

        // Apply quality adjustment
        uint256 qualityAdj = (usdValue * qualityBps) / BPS_DENOMINATOR;

        // Apply commitment multiplier
        uint256 commitBps  = commitmentMultipliers[vaultType];
        uint256 commitAdj  = (qualityAdj * commitBps) / BPS_DENOMINATOR;

        // Apply current emission factor (VCLM per $1)
        uint256 emission   = currentEmissionFactor();
        uint256 vclmAmount = (commitAdj * emission) / 1e18;

        return vclmAmount;
    }

    /**
     * @dev Atomically splits retained amount across three treasury pools.
     *      82% → Core Reserve Pool
     *      12% → Dev Fund
     *       6% → Ecosystem Fund
     *
     *      This is called in the same transaction as the deposit.
     *      The split is permanent and irreversible.
     */
    function _splitToTreasury(address asset, uint256 retained) internal {
        if (retained == 0) return;

        uint256 coreAmount  = (retained * CORE_RESERVE_BPS) / BPS_DENOMINATOR;
        uint256 devAmount   = (retained * DEV_FUND_BPS)     / BPS_DENOMINATOR;
        // Ecosystem gets remainder to avoid rounding dust
        uint256 ecoAmount   = retained - coreAmount - devAmount;

        IERC20(asset).safeTransfer(coreReservePool, coreAmount);
        IERC20(asset).safeTransfer(devFund,         devAmount);
        IERC20(asset).safeTransfer(ecosystemFund,   ecoAmount);

        emit TreasurySplit(asset, retained, coreAmount, devAmount, ecoAmount);
    }

    /**
     * @dev Returns principal to vault owner.
     *      Handles both ERC-20 and ETH (unwraps WETH for ETH vaults).
     */
    function _returnPrincipal(VaultEntry storage vault) internal {
        if (vault.isETH) {
            // Unwrap WETH and send ETH
            IWETH(weth).withdraw(vault.principal);
            (bool success, ) = vault.owner.call{value: vault.principal}("");
            require(success, "VM: ETH return failed");
        } else {
            IERC20(vault.asset).safeTransfer(vault.owner, vault.principal);
        }
    }

    /**
     * @dev Creates and stores a new vault entry.
     */
    function _createVault(
        address     owner,
        address     asset,
        VaultType   vaultType,
        VaultStatus status,
        uint256     grossDeposit,
        uint256     retained,
        uint256     principal,
        uint256     vclmMinted,
        bool        isETH
    ) internal returns (uint256 vaultId) {
        vaultCount++;
        vaultId = vaultCount;

        vaults[vaultId] = VaultEntry({
            vaultId:       vaultId,
            owner:         owner,
            asset:         asset,
            vaultType:     vaultType,
            status:        status,
            grossDeposit:  grossDeposit,
            retainedAmount: retained,
            principal:     principal,
            vclmMinted:    vclmMinted,
            openedAt:      block.timestamp,
            maturesAt:     0, // set by caller for standard vaults
            isETH:         isETH
        });

        ownerVaults[owner].push(vaultId);
    }

    /**
     * @dev Validates deposit cap for an asset.
     */
    function _checkDepositCap(address asset, uint256 amount) internal view {
        uint256 cap = depositCapByAsset[asset];
        if (cap > 0) {
            require(
                totalDepositedByAsset[asset] + amount <= cap,
                "VM: deposit cap reached for this asset"
            );
        }
    }

    /**
     * @dev Validates vault ownership.
     */
    function _requireVaultOwner(VaultEntry storage vault) internal view {
        require(vault.vaultId != 0,        "VM: vault does not exist");
        require(vault.owner == msg.sender,  "VM: not vault owner");
    }

    // ── ETH RECEIVE ──────────────────────────────────────────────────────────
    // Required to receive ETH from WETH unwrapping
    receive() external payable {
        require(msg.sender == weth, "VM: only WETH can send ETH");
    }
}
