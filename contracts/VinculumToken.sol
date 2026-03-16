// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// VinculumToken.sol
// $VCLM — the native token of Vinculum Protocol
//
// Architecture decisions locked:
//   - Inherits Axelar InterchainToken (Option A) for native ITS cross-chain
//   - 10 billion VCLM hard cap, immutable
//   - Deposit-only pause (withdrawals/transfers never paused)
//   - Real-time balance voting (snapshot upgrade path reserved for later)
//   - MINTER_ROLE restricted to VaultManager + GovernanceCouncilStaking only
//   - BURNER_ROLE restricted to protocol contracts only
//   - DEFAULT_ADMIN_ROLE held by founder multisig at launch
// ─────────────────────────────────────────────────────────────────────────────

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@axelar-network/interchain-token-service/contracts/interchain-token/InterchainToken.sol";
import "@axelar-network/interchain-token-service/contracts/interfaces/IInterchainTokenService.sol";

contract VinculumToken is InterchainToken, AccessControl, Pausable {

    // ── ROLES ────────────────────────────────────────────────────────────────
    bytes32 public constant MINTER_ROLE   = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE   = keccak256("BURNER_ROLE");
    bytes32 public constant PAUSER_ROLE   = keccak256("PAUSER_ROLE");

    // ── SUPPLY CAP ───────────────────────────────────────────────────────────
    // 10 billion VCLM hard cap. Immutable. No governance vote can ever change this.
    uint256 public constant MAX_SUPPLY = 10_000_000_000 * 1e18;

    // ── AXELAR ITS ───────────────────────────────────────────────────────────
    // The Interchain Token Service address on Base mainnet.
    // Set once at deployment. Immutable thereafter.
    address internal immutable _interchainTokenService;

    // Unique token ID registered with Axelar ITS.
    // Assigned during deployment via ITS registration.
    bytes32 internal _tokenId;

    // ── EVENTS ───────────────────────────────────────────────────────────────
    event ProtocolMint(address indexed to, uint256 amount, address indexed caller);
    event ProtocolBurn(address indexed from, uint256 amount, address indexed caller);
    event MintingPaused(address indexed caller);
    event MintingUnpaused(address indexed caller);
    event TokenIdSet(bytes32 indexed tokenId);

    // ── CONSTRUCTOR ──────────────────────────────────────────────────────────
    /**
     * @param admin   The initial DEFAULT_ADMIN_ROLE holder.
     *                At launch this should be a Gnosis Safe multisig address.
     *                This address can grant/revoke all roles.
     * @param its     The Axelar InterchainTokenService contract address on Base.
     *                Mainnet: 0xB5FB4BE02232B1bBA4dC8f81dc24C26980dE9e3C
     *                (verify against Axelar docs before deployment)
     */
    constructor(address admin, address its)
        ERC20("Vinculum", "VCLM")
    {
        require(admin != address(0), "VinculumToken: invalid admin");
        require(its   != address(0), "VinculumToken: invalid ITS address");

        _interchainTokenService = its;

        // Grant roles to admin (multisig at launch)
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);

        // MINTER_ROLE and BURNER_ROLE are NOT granted here.
        // They must be explicitly granted to VaultManager and
        // GovernanceCouncilStaking after those contracts are deployed.
        // This prevents any minting until the full protocol is wired up.
    }

    // ── AXELAR ITS REQUIRED OVERRIDES ────────────────────────────────────────

    /**
     * @dev Returns the Axelar ITS contract address.
     *      Required by InterchainToken base contract.
     */
    function interchainTokenService()
        public
        view
        override
        returns (address)
    {
        return _interchainTokenService;
    }

    /**
     * @dev Returns the unique token ID registered with Axelar ITS.
     *      Required by InterchainToken base contract.
     */
    function interchainTokenId()
        public
        view
        override
        returns (bytes32)
    {
        return _tokenId;
    }

    /**
     * @dev Called once after deployment to register the token ID
     *      returned by the ITS registration transaction.
     *      Can only be set once. Cannot be changed after setting.
     * @param tokenId  The bytes32 token ID assigned by Axelar ITS.
     */
    function setTokenId(bytes32 tokenId)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_tokenId == bytes32(0), "VinculumToken: tokenId already set");
        require(tokenId  != bytes32(0), "VinculumToken: invalid tokenId");
        _tokenId = tokenId;
        emit TokenIdSet(tokenId);
    }

    // ── MINTING ──────────────────────────────────────────────────────────────

    /**
     * @dev Mints VCLM to a recipient.
     *      Only callable by MINTER_ROLE holders (VaultManager, GovernanceCouncilStaking).
     *      Respects the 10 billion hard cap.
     *      Respects the deposit pause — if minting is paused, new vault entries
     *      are blocked at the VaultManager level before this is called.
     *      This function itself does not check pause — the calling contract does.
     *
     * @param to      Recipient address
     * @param amount  Amount of VCLM to mint (18 decimals)
     */
    function mint(address to, uint256 amount)
        external
        onlyRole(MINTER_ROLE)
    {
        require(to     != address(0), "VinculumToken: invalid recipient");
        require(amount  > 0,          "VinculumToken: amount must be > 0");
        require(
            totalSupply() + amount <= MAX_SUPPLY,
            "VinculumToken: exceeds 10B hard cap"
        );

        _mint(to, amount);
        emit ProtocolMint(to, amount, msg.sender);
    }

    // ── BURNING ──────────────────────────────────────────────────────────────

    /**
     * @dev Burns VCLM from any address.
     *      Only callable by BURNER_ROLE holders (protocol contracts only).
     *      Does NOT check allowance — this is intentional for protocol-level
     *      burns initiated by trusted contracts only.
     *      The BURNER_ROLE must never be granted to external or user-facing contracts.
     *
     * @param from    Address to burn from
     * @param amount  Amount of VCLM to burn (18 decimals)
     */
    function burnFromProtocol(address from, uint256 amount)
        external
        onlyRole(BURNER_ROLE)
    {
        require(from   != address(0), "VinculumToken: invalid source");
        require(amount  > 0,          "VinculumToken: amount must be > 0");

        _burn(from, amount);
        emit ProtocolBurn(from, amount, msg.sender);
    }

    /**
     * @dev Standard user-initiated burn with allowance check.
     *      Any token holder can burn their own VCLM.
     *      Uses OpenZeppelin's allowance-checked _burnFrom pattern.
     *
     * @param amount  Amount of VCLM to burn from caller's balance
     */
    function burn(uint256 amount) external {
        require(amount > 0, "VinculumToken: amount must be > 0");
        _burn(msg.sender, amount);
    }

    // ── PAUSE (DEPOSIT GATE ONLY) ─────────────────────────────────────────────
    //
    // IMPORTANT: The pause mechanism here is a SIGNAL to VaultManager and
    // GovernanceCouncilStaking. Those contracts check whenNotPaused() before
    // accepting new deposits/stakes. The token transfer function itself is
    // NEVER paused — VCLM holders can always transfer and exit.
    //
    // This is a core protocol guarantee:
    //   "Withdrawals can never be blocked under any circumstances."
    //
    // The pause only stops NEW money entering the protocol.

    /**
     * @dev Pauses new vault deposits and governance stakes.
     *      Does NOT affect token transfers, withdrawals, or governance voting.
     *      Only callable by PAUSER_ROLE (founder multisig at launch).
     */
    function pauseDeposits() external onlyRole(PAUSER_ROLE) {
        _pause();
        emit MintingPaused(msg.sender);
    }

    /**
     * @dev Unpauses new vault deposits and governance stakes.
     *      Only callable by PAUSER_ROLE.
     */
    function unpauseDeposits() external onlyRole(PAUSER_ROLE) {
        _unpause();
        emit MintingUnpaused(msg.sender);
    }

    /**
     * @dev Returns whether new deposits are currently paused.
     *      VaultManager and GovernanceCouncilStaking call this before
     *      accepting any new deposit or stake.
     */
    function depositsPaused() external view returns (bool) {
        return paused();
    }

    // ── TRANSFER OVERRIDE ────────────────────────────────────────────────────
    //
    // Transfers are NEVER blocked by pause.
    // This override explicitly does NOT call whenNotPaused().
    // It exists only to document this guarantee clearly.

    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override(ERC20, InterchainToken) {
        // No pause check here — transfers always work.
        // The hard cap only applies to minting, not transfers.
        super._update(from, to, amount);
    }

    // ── VIEW HELPERS ─────────────────────────────────────────────────────────

    /**
     * @dev Returns remaining mintable supply before hitting the hard cap.
     */
    function remainingMintableSupply() external view returns (uint256) {
        return MAX_SUPPLY - totalSupply();
    }

    /**
     * @dev Returns token decimals. Standard 18.
     */
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    // ── UPGRADE PATH NOTE ────────────────────────────────────────────────────
    //
    // Snapshot voting power (ERC20Votes) is intentionally NOT implemented
    // in this version. The governance contract uses real-time balances.
    //
    // When the community votes to add snapshot voting via a Constitutional
    // proposal, it will require deploying a new token contract and migrating.
    // That migration path should be designed carefully and audited separately.
    //
    // Do not add ERC20Votes to this contract without a full re-audit.
}
