// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// AssetRegistry.sol
// Canonical registry of approved vault assets for Vinculum Protocol
//
// Architecture decisions locked:
//   - Multi-oracle support (up to 5 oracles per asset)
//   - Median price aggregation across live oracles
//   - 1-hour staleness protection on all oracle prices
//   - Tier system: A / B / C / D with BPS quality multipliers
//   - 5-criteria approval bitmask — all 5 must be set to approve
//   - Asset approval routed through governance (ASSET_MANAGER_ROLE)
//   - Auto-revoke if criteria no longer met
//   - VaultManager reads price and quality from this registry
// ─────────────────────────────────────────────────────────────────────────────

import "@openzeppelin/contracts/access/AccessControl.sol";

// Oracle source interface — both Chainlink and Pyth adapters implement this
interface IOracleSource {
    function latestPrice() external view returns (uint256 price, uint256 updatedAt);
}

contract AssetRegistry is AccessControl {

    // ── ROLES ────────────────────────────────────────────────────────────────
    bytes32 public constant ASSET_MANAGER_ROLE  = keccak256("ASSET_MANAGER_ROLE");
    bytes32 public constant ORACLE_MANAGER_ROLE = keccak256("ORACLE_MANAGER_ROLE");

    // ── TIER SYSTEM ───────────────────────────────────────────────────────────
    // Quality multipliers in BPS applied to VCLM mint formula
    // Tier A: blue-chip assets — full multiplier
    // Tier B: established community tokens — 15% discount
    // Tier C: smaller community tokens — 30% discount
    // Tier D: speculative assets — 45% discount
    enum Tier { A, B, C, D }

    mapping(Tier => uint256) public tierMultiplierBps;

    // ── APPROVAL CRITERIA BITMASK ─────────────────────────────────────────────
    // All 5 bits must be set for an asset to be approved.
    // Bit 0: Liquidity sufficient
    // Bit 1: Contract verified on-chain
    // Bit 2: No malicious transfer logic detected
    // Bit 3: Oracle price feed available
    // Bit 4: Governance vote passed (or ASSET_MANAGER_ROLE approval)
    uint8 public constant CRITERIA_LIQUIDITY       = 1 << 0; // 0x01
    uint8 public constant CRITERIA_VERIFIED        = 1 << 1; // 0x02
    uint8 public constant CRITERIA_SAFE_TRANSFER   = 1 << 2; // 0x04
    uint8 public constant CRITERIA_ORACLE          = 1 << 3; // 0x08
    uint8 public constant CRITERIA_GOVERNANCE      = 1 << 4; // 0x10
    uint8 public constant CRITERIA_ALL             = 0x1F;   // all 5 bits

    // ── ORACLE CONFIG ─────────────────────────────────────────────────────────
    uint256 public constant MAX_ORACLES_PER_ASSET = 5;
    uint256 public constant STALENESS_THRESHOLD   = 1 hours;

    // ── ASSET STRUCT ─────────────────────────────────────────────────────────
    struct AssetConfig {
        address asset;
        bool    approved;
        Tier    tier;
        uint8   criteria;       // bitmask of approval criteria met
        string  symbol;         // human-readable symbol for UI
        string  revocationReason; // set when asset is revoked
        uint256 approvedAt;     // timestamp of approval
        uint256 revokedAt;      // timestamp of revocation (0 if active)
    }

    // ── STORAGE ──────────────────────────────────────────────────────────────
    // asset address => AssetConfig
    mapping(address => AssetConfig) public assets;

    // asset address => list of oracle addresses
    mapping(address => address[]) public assetOracles;

    // list of all approved asset addresses (for enumeration)
    address[] public approvedAssetList;

    // ── EVENTS ───────────────────────────────────────────────────────────────
    event AssetApproved(
        address indexed asset,
        string          symbol,
        Tier            tier,
        uint8           criteria
    );
    event AssetRevoked(
        address indexed asset,
        string          reason
    );
    event TierUpdated(
        address indexed asset,
        Tier            oldTier,
        Tier            newTier
    );
    event CriteriaUpdated(
        address indexed asset,
        uint8           oldCriteria,
        uint8           newCriteria
    );
    event OracleAdded(
        address indexed asset,
        address indexed oracle
    );
    event OracleRemoved(
        address indexed asset,
        address indexed oracle
    );

    // ── CONSTRUCTOR ──────────────────────────────────────────────────────────
    /**
     * @param admin  DEFAULT_ADMIN_ROLE holder (founder multisig)
     *               Also granted ASSET_MANAGER_ROLE and ORACLE_MANAGER_ROLE
     *               at launch. ASSET_MANAGER_ROLE transfers to governance
     *               at Milestone 2.
     */
    constructor(address admin) {
        require(admin != address(0), "AR: invalid admin");

        _grantRole(DEFAULT_ADMIN_ROLE,  admin);
        _grantRole(ASSET_MANAGER_ROLE,  admin);
        _grantRole(ORACLE_MANAGER_ROLE, admin);

        // Set tier multipliers
        tierMultiplierBps[Tier.A] = 10_000; // 1.00× — full rate
        tierMultiplierBps[Tier.B] =  8_500; // 0.85×
        tierMultiplierBps[Tier.C] =  7_000; // 0.70×
        tierMultiplierBps[Tier.D] =  5_500; // 0.55×
    }

    // ── ASSET APPROVAL ───────────────────────────────────────────────────────

    /**
     * @dev Approves an asset for use in commitment vaults.
     *      All 5 criteria bits must be set.
     *      Called by ASSET_MANAGER_ROLE.
     *      After Milestone 2 this role is held by governance.
     *
     * @param asset     ERC-20 token contract address
     * @param symbol    Human-readable token symbol (e.g. "ETH", "SHIB")
     * @param tier      Quality tier A/B/C/D
     * @param criteria  Bitmask of criteria met — must equal CRITERIA_ALL (0x1F)
     */
    function approveAsset(
        address asset,
        string calldata symbol,
        Tier    tier,
        uint8   criteria
    ) external onlyRole(ASSET_MANAGER_ROLE) {
        require(asset    != address(0),    "AR: invalid asset address");
        require(bytes(symbol).length > 0,  "AR: empty symbol");
        require(criteria == CRITERIA_ALL,  "AR: all 5 criteria must be met");
        require(!assets[asset].approved,   "AR: asset already approved");
        require(
            assetOracles[asset].length > 0,
            "AR: at least one oracle required before approval"
        );

        assets[asset] = AssetConfig({
            asset:            asset,
            approved:         true,
            tier:             tier,
            criteria:         criteria,
            symbol:           symbol,
            revocationReason: "",
            approvedAt:       block.timestamp,
            revokedAt:        0
        });

        approvedAssetList.push(asset);

        emit AssetApproved(asset, symbol, tier, criteria);
    }

    /**
     * @dev Revokes an approved asset.
     *      New vault deposits with this asset are blocked immediately.
     *      Existing vaults are unaffected — they can still withdraw at maturity.
     *      Called by ASSET_MANAGER_ROLE.
     *
     * @param asset   Asset to revoke
     * @param reason  Human-readable reason for revocation (stored on-chain)
     */
    function revokeAsset(address asset, string calldata reason)
        external
        onlyRole(ASSET_MANAGER_ROLE)
    {
        require(assets[asset].approved, "AR: asset not approved");
        require(bytes(reason).length > 0, "AR: reason required");

        assets[asset].approved          = false;
        assets[asset].revocationReason  = reason;
        assets[asset].revokedAt         = block.timestamp;

        // Remove from approved list
        _removeFromApprovedList(asset);

        emit AssetRevoked(asset, reason);
    }

    /**
     * @dev Updates the tier of an approved asset.
     *      Can upgrade (A→B is a downgrade in quality) or downgrade.
     *      Called by ASSET_MANAGER_ROLE.
     *
     * @param asset    Asset to update
     * @param newTier  New quality tier
     */
    function updateTier(address asset, Tier newTier)
        external
        onlyRole(ASSET_MANAGER_ROLE)
    {
        require(assets[asset].approved, "AR: asset not approved");

        Tier oldTier = assets[asset].tier;
        assets[asset].tier = newTier;

        emit TierUpdated(asset, oldTier, newTier);
    }

    /**
     * @dev Updates the criteria bitmask for an asset.
     *      If updated criteria no longer equals CRITERIA_ALL,
     *      the asset is automatically revoked.
     *      Called by ASSET_MANAGER_ROLE.
     *
     * @param asset       Asset to update
     * @param newCriteria New criteria bitmask
     */
    function updateCriteria(address asset, uint8 newCriteria)
        external
        onlyRole(ASSET_MANAGER_ROLE)
    {
        require(assets[asset].approved || assets[asset].approvedAt > 0, "AR: asset unknown");

        uint8 oldCriteria = assets[asset].criteria;
        assets[asset].criteria = newCriteria;

        emit CriteriaUpdated(asset, oldCriteria, newCriteria);

        // Auto-revoke if criteria no longer fully met
        if (assets[asset].approved && newCriteria != CRITERIA_ALL) {
            assets[asset].approved         = false;
            assets[asset].revocationReason = "Criteria no longer met";
            assets[asset].revokedAt        = block.timestamp;
            _removeFromApprovedList(asset);
            emit AssetRevoked(asset, "Criteria no longer met");
        }
    }

    // ── ORACLE MANAGEMENT ────────────────────────────────────────────────────

    /**
     * @dev Adds an oracle source for an asset.
     *      Maximum 5 oracles per asset.
     *      Called by ORACLE_MANAGER_ROLE.
     *
     * @param asset   Asset address
     * @param oracle  IOracleSource contract address (Chainlink or Pyth adapter)
     */
    function addOracle(address asset, address oracle)
        external
        onlyRole(ORACLE_MANAGER_ROLE)
    {
        require(asset  != address(0), "AR: invalid asset");
        require(oracle != address(0), "AR: invalid oracle");
        require(
            assetOracles[asset].length < MAX_ORACLES_PER_ASSET,
            "AR: max oracles reached"
        );

        // Check oracle isn't already added
        address[] storage oracles = assetOracles[asset];
        for (uint256 i = 0; i < oracles.length; i++) {
            require(oracles[i] != oracle, "AR: oracle already added");
        }

        assetOracles[asset].push(oracle);
        emit OracleAdded(asset, oracle);
    }

    /**
     * @dev Removes an oracle source for an asset.
     *      Called by ORACLE_MANAGER_ROLE.
     *      Note: if removal leaves zero oracles on an approved asset,
     *      the asset should be revoked separately.
     *
     * @param asset   Asset address
     * @param oracle  Oracle address to remove
     */
    function removeOracle(address asset, address oracle)
        external
        onlyRole(ORACLE_MANAGER_ROLE)
    {
        address[] storage oracles = assetOracles[asset];
        for (uint256 i = 0; i < oracles.length; i++) {
            if (oracles[i] == oracle) {
                oracles[i] = oracles[oracles.length - 1];
                oracles.pop();
                emit OracleRemoved(asset, oracle);
                return;
            }
        }
        revert("AR: oracle not found");
    }

    // ── PRICE AGGREGATION ────────────────────────────────────────────────────

    /**
     * @dev Returns the aggregated USD price for an asset.
     *      Queries all registered oracles, filters stale prices,
     *      and returns the median of live responses.
     *      Requires at least one live oracle response.
     *
     *      Called by VaultManager on every vault deposit.
     *
     * @param asset  Token address
     * @return price  Median USD price (18 decimals)
     */
    function getPrice(address asset) external view returns (uint256 price) {
        require(assets[asset].approved, "AR: asset not approved");
        return _medianPrice(asset);
    }

    /**
     * @dev Returns the quality multiplier BPS for an asset's tier.
     *      Called by VaultManager in the VCLM mint formula.
     *
     * @param asset  Token address
     * @return bps   Quality multiplier in BPS (e.g. 10000 = 1.0×)
     */
    function getQualityMultiplierBps(address asset)
        external
        view
        returns (uint256 bps)
    {
        require(assets[asset].approved, "AR: asset not approved");
        return tierMultiplierBps[assets[asset].tier];
    }

    /**
     * @dev Returns whether an asset is currently approved.
     */
    function isApproved(address asset) external view returns (bool) {
        return assets[asset].approved;
    }

    /**
     * @dev Returns full asset config.
     */
    function getAsset(address asset)
        external
        view
        returns (AssetConfig memory)
    {
        return assets[asset];
    }

    /**
     * @dev Returns all oracle addresses for an asset.
     */
    function getOracles(address asset)
        external
        view
        returns (address[] memory)
    {
        return assetOracles[asset];
    }

    /**
     * @dev Returns all currently approved assets.
     *      Used by the UI to display available vault assets.
     */
    function getAllApprovedAssets()
        external
        view
        returns (address[] memory)
    {
        return approvedAssetList;
    }

    /**
     * @dev Returns number of approved assets.
     */
    function approvedAssetCount() external view returns (uint256) {
        return approvedAssetList.length;
    }

    /**
     * @dev Non-reverting price peek — returns 0 if no live oracle.
     *      Used for monitoring and UI display without reverting.
     */
    function peekPrice(address asset)
        external
        view
        returns (uint256 price, uint256 liveOracleCount)
    {
        address[] storage oracles = assetOracles[asset];
        uint256[] memory prices   = new uint256[](oracles.length);
        uint256 count = 0;

        for (uint256 i = 0; i < oracles.length; i++) {
            try IOracleSource(oracles[i]).latestPrice() returns (
                uint256 p, uint256 updatedAt
            ) {
                if (
                    p > 0 &&
                    updatedAt > 0 &&
                    block.timestamp - updatedAt <= STALENESS_THRESHOLD
                ) {
                    prices[count] = p;
                    count++;
                }
            } catch {}
        }

        liveOracleCount = count;
        if (count == 0) return (0, 0);

        price = _median(prices, count);
    }

    // ── INTERNAL HELPERS ─────────────────────────────────────────────────────

    /**
     * @dev Queries all oracles for an asset, filters stale prices,
     *      and returns the median of live responses.
     *      Reverts if no live oracle is available.
     */
    function _medianPrice(address asset) internal view returns (uint256) {
        address[] storage oracles = assetOracles[asset];
        require(oracles.length > 0, "AR: no oracles configured");

        uint256[] memory prices = new uint256[](oracles.length);
        uint256 count = 0;

        for (uint256 i = 0; i < oracles.length; i++) {
            try IOracleSource(oracles[i]).latestPrice() returns (
                uint256 price, uint256 updatedAt
            ) {
                // Filter: price must be positive and not stale
                if (
                    price > 0 &&
                    updatedAt > 0 &&
                    block.timestamp - updatedAt <= STALENESS_THRESHOLD
                ) {
                    prices[count] = price;
                    count++;
                }
            } catch {
                // Oracle reverted — skip silently
            }
        }

        require(count > 0, "AR: no live oracle price available");

        return _median(prices, count);
    }

    /**
     * @dev Computes the median of the first `count` elements of `values`.
     *      Uses insertion sort (efficient for small arrays, max 5 elements).
     *
     * @param values  Array of prices (may have trailing zeros)
     * @param count   Number of valid values to consider
     * @return        Median value
     */
    function _median(uint256[] memory values, uint256 count)
        internal
        pure
        returns (uint256)
    {
        // Insertion sort on first `count` elements
        for (uint256 i = 1; i < count; i++) {
            uint256 key = values[i];
            uint256 j   = i;
            while (j > 0 && values[j - 1] > key) {
                values[j] = values[j - 1];
                j--;
            }
            values[j] = key;
        }

        // Return median
        if (count % 2 == 1) {
            return values[count / 2];
        } else {
            return (values[count / 2 - 1] + values[count / 2]) / 2;
        }
    }

    /**
     * @dev Removes an asset from the approvedAssetList array.
     *      Swap-and-pop for gas efficiency.
     */
    function _removeFromApprovedList(address asset) internal {
        uint256 len = approvedAssetList.length;
        for (uint256 i = 0; i < len; i++) {
            if (approvedAssetList[i] == asset) {
                approvedAssetList[i] = approvedAssetList[len - 1];
                approvedAssetList.pop();
                return;
            }
        }
    }

    // ── LAUNCH ASSET CONFIGURATION ───────────────────────────────────────────
    //
    // The following assets are approved at launch. Each requires:
    //   1. Oracle adapter deployed and added via addOracle()
    //   2. All 5 criteria confirmed
    //   3. approveAsset() called by ASSET_MANAGER_ROLE
    //
    // Launch asset list:
    //
    // TIER A (1.00×) — Blue chip / major stablecoins
    //   ETH  (via WETH on Base)   — Chainlink + Pyth
    //   USDC (Base native)        — Chainlink
    //   USDT (Base)               — Chainlink
    //   RLUSD (Ripple stablecoin) — Chainlink / Pyth TBD
    //   BASE token                — Chainlink / Pyth TBD
    //   XRP  (via Axelar/wrapped) — Chainlink + Pyth
    //   XLM  (via Axelar/wrapped) — Chainlink / Pyth TBD
    //   XDC  (via Axelar/wrapped) — Chainlink / Pyth TBD
    //
    // TIER B (0.85×) — Established community tokens
    //   SHIB (Base ERC-20)        — Chainlink + Pyth
    //   LUNC (Base ERC-20)        — Pyth
    //   VOLT (Base ERC-20)        — TBD
    //   WKC  (Base ERC-20)        — TBD
    //   KEKEC (Base ERC-20)       — TBD
    //
    // TIER C (0.70×) — Community / OG tokens
    //   TigerOG (Base ERC-20)     — TBD
    //   LionOG  (Base ERC-20)     — TBD
    //   FrogOG  (Base ERC-20)     — TBD
    //
    // Note: Assets without confirmed Chainlink/Pyth feeds at launch
    // will need a custom oracle adapter deployed before approval.
    // ─────────────────────────────────────────────────────────────────────────
}
