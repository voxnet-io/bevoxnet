// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {LibVoxTokenStorage} from "../libraries/LibVoxTokenStorage.sol";
import {LibVoxGovernanceStorage} from "../libraries/LibVoxGovernanceStorage.sol";
import {LibVoxStorage} from "../libraries/LibVoxStorage.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/**
 * @title VoxTokenFacet
 * @author Vox Team
 * @notice ERC20-compatible token implementation with integrated reward distribution and governance features
 * @dev This facet handles:
 *      - Token transfers with automatic reward distribution
 *      - POL (Polygon) and USDC reward claiming
 *      - Flash loan protection for voting mechanisms
 *      - Automatic vote adjustment on token transfers
 *      - Integration with OpenAdverts contract for USDC rewards
 *
 *      Security features:
 *      - Reentrancy protection on transfers and reward claims
 *      - 2-block cooldown after transfers before voting
 *      - Automatic undoVotes to prevent voting manipulation
 *      - Pre-transfer reward distribution to ensure fairness
 */
contract VoxTokenFacet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address internal immutable diamondAddressForDirectCalls;

    constructor(address _diamondAddress) {
        diamondAddressForDirectCalls = _diamondAddress;
    }
    // ============================================
    // EVENTS
    // ============================================

    /**
     * @notice Emitted when the USDC token address is updated
     * @param newAddress The new USDC token contract address
     */
    event USDCAddressUpdated(address indexed newAddress);

    /**
     * @notice Emitted when the price feed address is updated
     * @param newAddress The new Chainlink price feed address
     */
    event PriceFeedAddressUpdated(address indexed newAddress);

    /**
     * @notice Emitted when the OpenAdverts contract address is updated
     * @param newAddress The new OpenAdverts contract address
     */
    event OpenAdvertsAddressUpdated(address indexed newAddress);

    /**
     * @notice Emitted when USDC is deposited and split between admin and token holders
     * @param depositor The address that deposited USDC
     * @param totalAmount The total USDC amount deposited
     * @param adminAmount The amount allocated to admin
     * @param holderAmount The amount allocated to token holders
     */
    event USDCDeposited(address indexed depositor, uint256 totalAmount, uint256 adminAmount, uint256 holderAmount);

    /**
     * @notice Emitted when funds forfeited by a banned/removed chapter are routed
     *         100% to the token-holder reward pool (no admin or storage-provider cut).
     * @param chapter The chapter contract that forfeited the funds
     * @param polAmount POL routed to the holder reward pool
     * @param usdcAmount USDC routed to the holder reward pool
     */
    event ForfeitedFundsRouted(address indexed chapter, uint256 polAmount, uint256 usdcAmount);

    /**
     * @notice Emitted when admin withdraws their accumulated USDC
     * @param admin The admin address
     * @param amount The amount withdrawn
     */
    event AdminUSDCWithdrawn(address indexed admin, uint256 amount);

    /**
     * @notice Emitted when admin withdraws accumulated POL rewards
     * @param admin The admin address
     * @param amount The amount withdrawn
     */
    event AdminPOLWithdrawn(address indexed admin, uint256 amount);

    /**
     * @notice Emitted when a holder successfully claims accrued rewards
     * @param account The account that claimed rewards
     * @param polAmount The POL amount claimed
     * @param usdcAmount The USDC amount claimed
     */
    event RewardsClaimed(address indexed account, uint256 polAmount, uint256 usdcAmount);

    /**
     * @notice Emitted when rewards are accrued for an account (cursor advanced, balance credited)
     * @param account The account whose rewards were accrued
     * @param polAmount The POL amount accrued
     * @param usdcAmount The USDC amount accrued
     */
    event RewardsAccrued(address indexed account, uint256 polAmount, uint256 usdcAmount);

    /**
     * @notice Emitted on every token transfer, including mints and burns
     * @dev Required by ERC-20 standard (EIP-20)
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @notice Emitted when an allowance is set via approve()
     * @dev Required by ERC-20 standard (EIP-20)
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ============================================
    // MODIFIERS
    // ============================================

    /**
     * @notice Prevents flash loan attacks and voting manipulation
     * @dev Implements a 2-block cooldown mechanism using msg.sender only:
     *      1. Checks that msg.sender hasn't transferred or voted in the last 2 blocks
     *      2. Records vote activity after function execution
     *
     *      This prevents:
     *      - Borrowing tokens, voting, and returning them in same transaction
     *      - Vote manipulation via temporary token acquisition
     *      - Same-block voting after receiving tokens
     */
    modifier flashLoanProtection() {
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();

        require(canVoteThisBlock(msg.sender), "Cannot vote: recent transfer or voting activity");

        _;

        ts.lastVoteBlock[msg.sender] = block.number;
    }

    // ============================================
    // INITIALIZATION
    // ============================================

    /**
     * @notice Initializes the token with oracle addresses and mints initial supply
     * @dev Can only be called once by the contract owner. Mints 21 million tokens to the deployer.
     *      Sets up integration with USDC, Chainlink price feed, and OpenAdverts contract.
     *
     * @param _usdcTokenAddress The address of the USDC token contract for reward distribution
     * @param _priceFeedAddress The address of the Chainlink POL/USD price feed
     * @param _openAdvertsContractAddress The address of the OpenAdverts contract for USDC rewards
     *
     * Token Details:
     * - Name: "Vox"
     * - Symbol: "VOX"
     * - Decimals: 18
     * - Total Supply: 21,000,000 VOX
     *
     * Requirements:
     * - Must not be already initialized
     * - All addresses must be non-zero
     * - Caller must be contract owner
     *
     * Emits: Transfer event from address(0) to deployer for initial minting
     *
     * State Changes:
     * - Sets total supply to 21M tokens
     * - Mints entire supply to deployer
     * - Records oracle addresses
     * - Marks contract as initialized
     */
    function initialize(address _diamondAddress, address _usdcTokenAddress, address _priceFeedAddress, address _openAdvertsContractAddress) external {
        LibDiamond.enforceIsContractOwner();
        LibVoxTokenStorage.TokenStorage storage tokenStorage = LibVoxTokenStorage.tokenStorage();

        require(!tokenStorage.initialized, "Already initialized");
        require(_diamondAddress != address(0), "Invalid diamond address");
        require(_usdcTokenAddress != address(0), "Invalid USDC address");
        require(_priceFeedAddress != address(0), "Invalid price feed address");
        require(_openAdvertsContractAddress != address(0), "Invalid OpenAdverts contract address");

        tokenStorage.diamondAddress = _diamondAddress;
        tokenStorage.totalSupply = 21000000 * 10 ** 18;
        tokenStorage.name = "Vox";
        tokenStorage.symbol = "VOX";

        tokenStorage.usdcTokenAddress = _usdcTokenAddress;
        tokenStorage.priceFeedAddress = _priceFeedAddress;
        tokenStorage.openAdvertsContractAddress = _openAdvertsContractAddress;

        tokenStorage.initialized = true;

        address deployer = msg.sender;
        tokenStorage.balances[deployer] += tokenStorage.totalSupply;
        emit Transfer(address(0), deployer, tokenStorage.totalSupply);
    }

    // ============================================
    // USDC DEPOSIT & ADMIN WITHDRAWAL FUNCTIONS
    // ============================================

    /**
     * @notice Internal function to detect and process new USDC deposits
     * @dev Compares current USDC balance with last known balance to detect deposits.
     *      Works with ANY deposit method (direct transfers, approved deposits, etc).
     *      Implements 3-step waterfall allocation matching POL receive():
     *      1. Storage provider cut (tracked for offchain Turbo topup)
     *      2. Admin claim (tracked for withdrawal)
     *      3. Bounty pool (remaining funds for reward distribution)
     *
     * Process:
     * 1. Query current USDC balance of contract
     * 2. Compare to lastKnownUSDCBalance
     * 3. If balance increased, calculate delta (new deposits)
     * 4. Apply 3-step waterfall split
     * 5. Update lastKnownUSDCBalance
     *
     * Emits: USDCDeposited event if new deposits detected
     *
     * State Changes:
     * - Updates storageProviderUSDCBalance
     * - Updates totalAggregateAdminUSDC
     * - Updates totalAggregateRewardInUSDC
     * - Updates lastKnownUSDCBalance
     *
     * @custom:pattern Called at start of every USDC operation to catch external deposits
     * @custom:safety Handles direct ERC20 transfers that contract can't normally detect
     */
    function processNewUSDCDeposits() internal {
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();

        if (ts.usdcTokenAddress == address(0)) return;

        IERC20 usdcToken = IERC20(ts.usdcTokenAddress);
        uint256 currentBalance = usdcToken.balanceOf(address(this));
        uint256 lastKnown = ts.lastKnownUSDCBalance;

        // Check if new deposits arrived
        if (currentBalance > lastKnown) {
            uint256 newDeposits = currentBalance - lastKnown;

            LibVoxGovernanceStorage.GovernanceStorage storage gs = LibVoxGovernanceStorage.governanceStorage();

            // Step 1: Storage provider cut (tracked, not transferred)
            uint256 storagePct = gs.currentQuotas.storageProviderPercentage;
            uint256 storageAmount = (newDeposits * storagePct) / 100;
            // Defense-in-depth saturating cap — see Diamond.receive() for rationale.
            if (storageAmount > newDeposits) {
                storageAmount = newDeposits;
            }
            ts.storageProviderUSDCBalance += storageAmount;

            uint256 afterStorage = newDeposits - storageAmount;

            // Step 2: Admin claim (tracked for withdrawal)
            uint256 adminClaimPct = gs.currentQuotas.voxAdminClaimPercentage;
            uint256 adminAmount = (afterStorage * adminClaimPct) / 100;
            if (adminAmount > afterStorage) {
                adminAmount = afterStorage;
            }
            ts.totalAggregateAdminUSDC += adminAmount;

            // Step 3: Bounty pool (remaining funds)
            uint256 holderAmount = afterStorage - adminAmount;
            ts.totalAggregateRewardInUSDC += holderAmount;

            ts.lastKnownUSDCBalance = currentBalance;

            emit USDCDeposited(address(0), newDeposits, adminAmount, holderAmount);
        }
    }

    /**
     * @notice Optional explicit deposit function for USDC rewards
     * @dev Allows external contracts to explicitly deposit and trigger processing.
     *      Not required - direct transfers work too, but this provides immediate confirmation.
     *
     * @param amount The USDC amount to deposit
     *
     * Requirements:
     * - Caller must have approved this contract to spend USDC
     * - Amount must be greater than 0
     *
     * Emits: USDCDeposited event with split details
     */
    function depositUSDCForRewards(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");

        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();
        require(ts.usdcTokenAddress != address(0), "USDC token address not set");

        // Transfer USDC from caller to this contract
        IERC20 usdcToken = IERC20(ts.usdcTokenAddress);
        require(usdcToken.transferFrom(msg.sender, address(this), amount), "USDC transfer failed");

        // Process the deposit (will detect the balance increase)
        processNewUSDCDeposits();
    }

    /**
     * @notice Receives funds forfeited by a banned or removed chapter and routes them
     *         100% to the token-holder reward pool — bypassing the storage-provider and
     *         admin-claim slices of the normal deposit waterfall.
     * @dev Callable ONLY by a chapter contract the Diamond has marked banned or removed
     *      (msg.sender must satisfy isChapterBanned || isChapterRemoved in main storage).
     *      This is the sole entry point that credits the reward aggregates without an
     *      admin cut; it exists so forfeited creator funds are redistributed to the
     *      community rather than accruing to operator revenue.
     *
     *      POL is delivered as msg.value. USDC is pulled via transferFrom, so the calling
     *      chapter must have approved this Diamond for `usdcAmount` beforehand.
     *
     *      USDC accounting: any pre-existing untracked USDC delta is reconciled through
     *      the NORMAL split first (processNewUSDCDeposits), then the forfeited amount is
     *      credited 100% to the holder pool and lastKnownUSDCBalance is advanced by
     *      exactly the received amount. This preserves the invariant
     *      lastKnownUSDCBalance == balanceOf(this) so the forfeited funds can never be
     *      re-detected and re-split (which would silently hand the admin a cut).
     * @param usdcAmount Amount of USDC to pull from the caller (0 if none).
     *
     * Requirements:
     * - Caller must be a chapter contract flagged banned or removed in main storage
     * - If usdcAmount > 0, the USDC token must be configured and the caller must have
     *   approved this Diamond for at least `usdcAmount`
     */
    function depositForfeitedFunds(uint256 usdcAmount) external payable nonReentrant {
        LibVoxStorage.VoxMainStorage storage ms = LibVoxStorage.mainStorage();
        require(ms.isChapterBanned[msg.sender] || ms.isChapterRemoved[msg.sender], "Not a forfeitable chapter");

        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();

        // POL: credit the full swept amount to the holder reward pool (no admin/storage cut).
        if (msg.value > 0) {
            ts.totalAggregateRewardInPOLWei += msg.value;
        }

        // USDC: pull via transferFrom and credit the full received amount to the holder pool.
        if (usdcAmount > 0) {
            require(ts.usdcTokenAddress != address(0), "USDC token address not set");

            // Split any pre-existing untracked deposits normally BEFORE pulling the
            // forfeited funds, so only genuine content revenue takes the admin cut.
            processNewUSDCDeposits();

            IERC20 usdcToken = IERC20(ts.usdcTokenAddress);
            uint256 balanceBefore = usdcToken.balanceOf(address(this));
            usdcToken.safeTransferFrom(msg.sender, address(this), usdcAmount);
            uint256 received = usdcToken.balanceOf(address(this)) - balanceBefore;

            ts.totalAggregateRewardInUSDC += received;
            // Advance the delta cursor by exactly what we received so the forfeited
            // funds are not re-detected and re-split on the next deposit scan.
            ts.lastKnownUSDCBalance += received;
        }

        emit ForfeitedFundsRouted(msg.sender, msg.value, usdcAmount);
    }

    /**
     * @notice Allows admin to withdraw accumulated USDC rewards
     * @dev Only callable by contract owner. First processes any new deposits, then withdraws.
     *      Available amount = totalAggregateAdminUSDC - adminWithdrawnUSDC
     *
     * Requirements:
     * - Caller must be contract owner
     * - Must have USDC available to withdraw
     * - Contract must have sufficient USDC balance
     *
     * Emits: AdminUSDCWithdrawn event with withdrawal amount
     *
     * State Changes:
     * - Processes new deposits if any (splits them)
     * - Transfers USDC from contract to admin
     * - Updates adminWithdrawnUSDC
     * - Updates lastKnownUSDCBalance
     *
     * @custom:security Only owner can withdraw
     * @custom:pattern Detects direct transfers before withdrawal
     */
    function withdrawAdminUSDC() external nonReentrant {
        LibDiamond.enforceIsContractOwner();
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();

        require(ts.usdcTokenAddress != address(0), "USDC token address not set");

        // Process any new deposits first
        processNewUSDCDeposits();

        // Calculate available amount
        uint256 availableAmount = ts.totalAggregateAdminUSDC - ts.adminWithdrawnUSDC;
        require(availableAmount > 0, "No USDC available to withdraw");

        // Verify contract has sufficient balance
        IERC20 usdcToken = IERC20(ts.usdcTokenAddress);
        uint256 contractBalance = usdcToken.balanceOf(address(this));
        require(contractBalance >= availableAmount, "Insufficient USDC balance in contract");

        // Update withdrawn amount before transfer (reentrancy protection)
        ts.adminWithdrawnUSDC += availableAmount;

        // Transfer to admin
        usdcToken.safeTransfer(msg.sender, availableAmount);

        // Update last known balance after transfer
        ts.lastKnownUSDCBalance = usdcToken.balanceOf(address(this));

        emit AdminUSDCWithdrawn(msg.sender, availableAmount);
    }

    /**
     * @notice Returns admin's available USDC withdrawal amount
     * @dev Simulates deposit detection without writing to storage.
     *      The actual withdrawAdminUSDC() calls processNewUSDCDeposits() before computing,
     *      so accuracy at execution time is preserved.
     * @return availableAmount The amount of USDC admin can withdraw
     */
    function getAdminAvailableUSDC() external view returns (uint256 availableAmount) {
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();

        // Simulate deposit detection without writing to storage
        uint256 pendingAdminUSDC = ts.totalAggregateAdminUSDC;
        if (ts.usdcTokenAddress != address(0)) {
            uint256 currentBalance = IERC20(ts.usdcTokenAddress).balanceOf(address(this));
            if (currentBalance > ts.lastKnownUSDCBalance) {
                uint256 newDeposits = currentBalance - ts.lastKnownUSDCBalance;
                LibVoxGovernanceStorage.GovernanceStorage storage gs = LibVoxGovernanceStorage.governanceStorage();
                uint256 storageAmount = (newDeposits * gs.currentQuotas.storageProviderPercentage) / 100;
                if (storageAmount > newDeposits) {
                    storageAmount = newDeposits;
                }
                uint256 afterStorage = newDeposits - storageAmount;
                uint256 adminAmount = (afterStorage * gs.currentQuotas.voxAdminClaimPercentage) / 100;
                if (adminAmount > afterStorage) {
                    adminAmount = afterStorage;
                }
                pendingAdminUSDC += adminAmount;
            }
        }

        return pendingAdminUSDC - ts.adminWithdrawnUSDC;
    }

    /**
     * @notice Allows admin to withdraw accumulated POL rewards
     * @dev Only callable by contract owner. Transfers accumulated admin POL slice.
     *      Available amount = totalAggregateAdminPOL - adminWithdrawnPOL
     *
     * Requirements:
     * - Caller must be contract owner
     * - Must have POL available to withdraw
     * - Contract must have sufficient POL balance
     *
     * Emits: AdminPOLWithdrawn event with withdrawal amount
     *
     * State Changes:
     * - Updates adminWithdrawnPOL
     */
    function withdrawAdminPOL() external nonReentrant {
        LibDiamond.enforceIsContractOwner();
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();

        uint256 availableAmount = ts.totalAggregateAdminPOL - ts.adminWithdrawnPOL;
        require(availableAmount > 0, "No POL available to withdraw");
        require(address(this).balance >= availableAmount, "Insufficient POL balance in contract");

        // Update withdrawn amount before transfer (reentrancy protection)
        ts.adminWithdrawnPOL += availableAmount;

        (bool success, ) = payable(msg.sender).call{value: availableAmount}("");
        require(success, "POL transfer to admin failed");

        emit AdminPOLWithdrawn(msg.sender, availableAmount);
    }

    /**
     * @notice Returns admin's available POL withdrawal amount
     * @return availableAmount The amount of POL admin can withdraw
     */
    function getAdminAvailablePOL() external view returns (uint256 availableAmount) {
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();
        return ts.totalAggregateAdminPOL - ts.adminWithdrawnPOL;
    }

    // ============================================
    // CONFIGURATION FUNCTIONS (OWNER ONLY)
    // ============================================

    /**
     * @notice Updates the USDC token contract address
     * @dev Only callable by the contract owner. Used for reward distribution in USDC.
     *
     * @param _usdcTokenAddress The new USDC token contract address
     *
     * Requirements:
     * - Caller must be contract owner
     * - Address cannot be zero address
     *
     * Emits: USDCAddressUpdated event with the new address
     *
     * State Changes:
     * - Updates tokenStorage.usdcTokenAddress
     */
    function setUSDCAddress(address _usdcTokenAddress) external {
        LibDiamond.enforceIsContractOwner();
        require(_usdcTokenAddress != address(0), "Invalid USDC address");

        LibVoxTokenStorage.TokenStorage storage tokenStorage = LibVoxTokenStorage.tokenStorage();
        tokenStorage.usdcTokenAddress = _usdcTokenAddress;

        emit USDCAddressUpdated(_usdcTokenAddress);
    }

    /**
     * @notice Updates the Chainlink price feed address
     * @dev Only callable by the contract owner. Used for POL/USD price conversions.
     *
     * @param _priceFeedAddress The new Chainlink price feed address
     *
     * Requirements:
     * - Caller must be contract owner
     * - Address cannot be zero address
     *
     * Emits: PriceFeedAddressUpdated event with the new address
     *
     * State Changes:
     * - Updates tokenStorage.priceFeedAddress
     */
    function setPriceFeedAddress(address _priceFeedAddress) external {
        LibDiamond.enforceIsContractOwner();
        require(_priceFeedAddress != address(0), "Invalid price feed address");

        LibVoxTokenStorage.TokenStorage storage tokenStorage = LibVoxTokenStorage.tokenStorage();
        tokenStorage.priceFeedAddress = _priceFeedAddress;

        emit PriceFeedAddressUpdated(_priceFeedAddress);
    }

    /**
     * @notice Updates the OpenAdverts contract address
     * @dev Only callable by the contract owner. The OpenAdverts contract provides USDC rewards.
     *
     * @param _openAdvertsContractAddress The new OpenAdverts contract address
     *
     * Requirements:
     * - Caller must be contract owner
     * - Address cannot be zero address
     *
     * Emits: OpenAdvertsAddressUpdated event with the new address
     *
     * State Changes:
     * - Updates tokenStorage.openAdvertsContractAddress
     */
    function setOpenAdvertsContractAddress(address _openAdvertsContractAddress) external {
        LibDiamond.enforceIsContractOwner();
        require(_openAdvertsContractAddress != address(0), "Invalid OpenAdverts contract address");

        LibVoxTokenStorage.TokenStorage storage tokenStorage = LibVoxTokenStorage.tokenStorage();
        tokenStorage.openAdvertsContractAddress = _openAdvertsContractAddress;

        emit OpenAdvertsAddressUpdated(_openAdvertsContractAddress);
    }

    // ============================================
    // TOKEN TRANSFER FUNCTIONS
    // ============================================

    /**
     * @notice Transfers tokens from the sender to a recipient
     * @dev Implements ERC20 transfer with additional features:
     *      1. Records transfer blocks for flash loan protection
     *      2. Initializes reward tracking for new recipients
     *      3. Distributes pending rewards BEFORE transfer (using pre-transfer balances)
     *      4. Adjusts voting power via undoVotes
     *      5. Executes the actual token transfer
     *
     * @param recipient The address receiving the tokens
     * @param amount The amount of tokens to transfer (in wei, 18 decimals)
     * @return bool True if the transfer succeeded
     *
     * Transfer Flow:
     * 1. Record transfer block for both sender and recipient
     * 2. If recipient is new (zero balance), initialize reward tracking
     * 3. Distribute rewards to sender (based on OLD balance)
     * 4. Distribute rewards to recipient (based on OLD balance)
     * 5. Reduce sender's voting power proportionally
     * 6. Transfer tokens
     *
     * Requirements:
     * - Sender must have sufficient balance
     * - Recipient cannot be zero address
     *
     * Emits: Transfer event with sender, recipient, and amount
     * Emits: DividendDistributed events for both parties (if rewards > 0)
     *
     * State Changes:
     * - Updates lastTransferBlock for sender and recipient
     * - Initializes reward tracking for new recipients
     * - Distributes pending rewards
     * - Reduces sender's votes on active proposals/admin elections
     * - Updates token balances
     *
     * @custom:security Reentrancy protected
     * @custom:fairness Rewards distributed before transfer ensures fair allocation
     */
    function transfer(address recipient, uint256 amount) public virtual nonReentrant returns (bool) {
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();

        ts.lastTransferBlock[msg.sender] = block.number;
        ts.lastTransferBlock[recipient] = block.number;

        if (ts.balances[recipient] == 0 && amount > 0) {
            ts.lastRewardClaimInPOL[recipient] = ts.totalAggregateRewardInPOLWei;
            ts.lastRewardClaimInUSDC[recipient] = ts.totalAggregateRewardInUSDC;
        }

        _accrue(msg.sender);
        _accrue(recipient);

        undoVotes(msg.sender, amount);

        _transferCustom(msg.sender, recipient, amount);

        return true;
    }

    /**
     * @notice Approves a spender to transfer tokens on behalf of the caller
     * @dev Standard ERC-20 approve. Does not distribute rewards or check flash loan protection.
     *      For security, prefer approve(spender, 0) before setting a new non-zero allowance.
     *
     * @param spender The address allowed to spend
     * @param amount The maximum amount the spender may transfer
     * @return bool True on success
     *
     * Emits: Approval event
     */
    function approve(address spender, uint256 amount) external returns (bool) {
        require(spender != address(0), "ERC20: approve to the zero address");
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();
        ts.allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice Returns the remaining number of tokens the spender is allowed to spend
     * @param owner The token holder
     * @param spender The approved spender
     * @return uint256 Remaining allowance
     */
    function allowance(address owner, address spender) external view returns (uint256) {
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();
        return ts.allowances[owner][spender];
    }

    /**
     * @notice Transfers tokens from one address to another using a pre-approved allowance
     * @dev Follows the same reward-distribution and vote-adjustment flow as transfer().
     *      The caller must have been approved by `sender` via approve().
     *
     * @param sender The address to transfer from
     * @param recipient The address to transfer to
     * @param amount The amount to transfer
     * @return bool True on success
     *
     * Requirements:
     * - Caller must have sufficient allowance from sender
     * - sender must have sufficient balance
     *
     * Emits: Transfer event
     * Emits: Approval event (updated allowance)
     */
    function transferFrom(address sender, address recipient, uint256 amount) external nonReentrant returns (bool) {
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();

        uint256 currentAllowance = ts.allowances[sender][msg.sender];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");

        // Deduct allowance (underflow impossible due to require above)
        unchecked {
            ts.allowances[sender][msg.sender] = currentAllowance - amount;
        }
        emit Approval(sender, msg.sender, ts.allowances[sender][msg.sender]);

        // Apply the same pre-transfer accounting as transfer()
        ts.lastTransferBlock[sender] = block.number;
        ts.lastTransferBlock[recipient] = block.number;

        if (ts.balances[recipient] == 0 && amount > 0) {
            ts.lastRewardClaimInPOL[recipient] = ts.totalAggregateRewardInPOLWei;
            ts.lastRewardClaimInUSDC[recipient] = ts.totalAggregateRewardInUSDC;
        }

        _accrue(sender);
        _accrue(recipient);

        undoVotes(sender, amount);

        _transferCustom(sender, recipient, amount);

        return true;
    }

    /**
     * @notice Internal function to execute token transfers
     * @dev Validates addresses, checks balance, and updates balances.
     *      This is the core transfer logic separated for internal use.
     *
     * @param sender The address sending tokens
     * @param recipient The address receiving tokens
     * @param amount The amount of tokens to transfer
     *
     * Requirements:
     * - Sender cannot be zero address
     * - Recipient cannot be zero address
     * - Sender must have sufficient balance
     *
     * Emits: Transfer event
     *
     * State Changes:
     * - Decreases sender's balance
     * - Increases recipient's balance
     */
    function _transferCustom(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), "ERC20: Invalid sender address");
        require(recipient != address(0), "ERC20: Invalid receiver address");

        LibVoxTokenStorage.TokenStorage storage tokenStorage = LibVoxTokenStorage.tokenStorage();
        require(tokenStorage.balances[sender] >= amount, "ERC20: transfer amount exceeds balance");

        tokenStorage.balances[sender] -= amount;
        tokenStorage.balances[recipient] += amount;
        emit Transfer(sender, recipient, amount);
    }

    // ============================================
    // REWARD ACCRUAL & CLAIM FUNCTIONS
    // ============================================

    /**
     * @notice Accrues pending rewards into the account's unclaimed balance
     * @dev Converts the cursor gap (rewards accumulated since last accrual) into
     *      credited unclaimed balances. No funds are transferred — this is a pure
     *      bookkeeping operation. Called automatically on every transfer so that
     *      reward splits are calculated against pre-transfer balances.
     *
     *      Process:
     *      1. Process any new USDC deposits (detects direct transfers)
     *      2. Calculate POL/USDC owed since last accrual via cursor gap
     *      3. Credit amounts to unclaimedPOL / unclaimedUSDC
     *      4. Advance cursors to current aggregate totals
     *
     * @param account The address to accrue rewards for
     *
     * State Changes:
     * - Processes new USDC deposits (updates aggregates)
     * - Updates unclaimedPOL[account]
     * - Updates unclaimedUSDC[account]
     * - Updates lastRewardClaimInPOL[account]
     * - Updates lastRewardClaimInUSDC[account]
     *
     * Emits: RewardsAccrued if non-zero amounts were accrued
     */
    function _accrue(address account) internal {
        processNewUSDCDeposits();

        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();

        uint256 polOwed = calculateRewardPOL(account);
        uint256 usdcOwed = calculateRewardUSDC(account);

        if (polOwed > 0) {
            ts.unclaimedPOL[account] += polOwed;
            ts.lastRewardClaimInPOL[account] = ts.totalAggregateRewardInPOLWei;
        }

        if (usdcOwed > 0) {
            ts.unclaimedUSDC[account] += usdcOwed;
            ts.lastRewardClaimInUSDC[account] = ts.totalAggregateRewardInUSDC;
        }

        if (polOwed > 0 || usdcOwed > 0) {
            emit RewardsAccrued(account, polOwed, usdcOwed);
        }
    }

    /**
     * @notice Claims all accrued POL and USDC rewards for the caller
     * @dev Pull-model claim: only msg.sender can withdraw their own rewards.
     *      Accrues any pending cursor gap first, then transfers the full
     *      unclaimed balance. Follows checks-effects-interactions (CEI).
     *
     * Requirements:
     * - Caller must have non-zero accrued rewards
     * - Contract must hold sufficient POL and USDC balances
     *
     * Emits: RewardsClaimed event with amounts sent
     *
     * State Changes:
     * - Accrues pending rewards (advances cursors)
     * - Zeroes unclaimedPOL[msg.sender] and unclaimedUSDC[msg.sender]
     * - Transfers POL via low-level call to msg.sender
     * - Transfers USDC via ERC20 transfer to msg.sender
     * - Updates lastKnownUSDCBalance
     */
    function claimRewards() external nonReentrant {
        _accrue(msg.sender);

        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();

        uint256 polAmount = ts.unclaimedPOL[msg.sender];
        uint256 usdcAmount = ts.unclaimedUSDC[msg.sender];

        require(polAmount > 0 || usdcAmount > 0, "No rewards to claim");

        // Effects: zero balances before interactions (CEI)
        ts.unclaimedPOL[msg.sender] = 0;
        ts.unclaimedUSDC[msg.sender] = 0;

        // Interactions: send POL
        if (polAmount > 0) {
            (bool polSuccess, ) = payable(msg.sender).call{value: polAmount}("");
            require(polSuccess, "POL transfer failed");
        }

        // Interactions: send USDC
        if (usdcAmount > 0) {
            require(ts.usdcTokenAddress != address(0), "USDC token address not set");
            IERC20 usdcToken = IERC20(ts.usdcTokenAddress);
            require(usdcToken.balanceOf(address(this)) >= usdcAmount, "Insufficient USDC balance");
            usdcToken.safeTransfer(msg.sender, usdcAmount);
            ts.lastKnownUSDCBalance = usdcToken.balanceOf(address(this));
        }

        emit RewardsClaimed(msg.sender, polAmount, usdcAmount);
    }

    /**
     * @notice Returns the total pending rewards for an account (accrued + unaccrued cursor gap)
     * @dev View function that simulates USDC deposit detection for accuracy.
     *      Does NOT modify state.
     *
     * @param account The address to query
     * @return polReward Total pending POL reward in wei
     * @return usdcReward Total pending USDC reward in USDC units
     */
    function pendingRewards(address account) external view returns (uint256 polReward, uint256 usdcReward) {
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();

        // Start with already-accrued unclaimed balances
        polReward = ts.unclaimedPOL[account];
        usdcReward = ts.unclaimedUSDC[account];

        // Add unaccrued cursor gap for POL (no simulation needed — POL aggregates update on receive())
        polReward += calculateRewardPOL(account);

        // Add unaccrued cursor gap for USDC, simulating unprocessed deposit detection
        uint256 effectiveTotalUSDC = ts.totalAggregateRewardInUSDC;
        if (ts.usdcTokenAddress != address(0)) {
            uint256 currentBalance = IERC20(ts.usdcTokenAddress).balanceOf(address(this));
            if (currentBalance > ts.lastKnownUSDCBalance) {
                uint256 newDeposits = currentBalance - ts.lastKnownUSDCBalance;
                LibVoxGovernanceStorage.GovernanceStorage storage gs = LibVoxGovernanceStorage.governanceStorage();
                uint256 storageAmount = (newDeposits * gs.currentQuotas.storageProviderPercentage) / 100;
                if (storageAmount > newDeposits) {
                    storageAmount = newDeposits;
                }
                uint256 afterStorage = newDeposits - storageAmount;
                uint256 adminAmount = (afterStorage * gs.currentQuotas.voxAdminClaimPercentage) / 100;
                if (adminAmount > afterStorage) {
                    adminAmount = afterStorage;
                }
                effectiveTotalUSDC += (afterStorage - adminAmount);
            }
        }

        // Calculate USDC cursor gap against effective total
        uint256 accountBalance = balanceOf(account);
        if (accountBalance > 0 && effectiveTotalUSDC > 0 && totalSupply() > 0) {
            uint256 lastClaimed = ts.lastRewardClaimInUSDC[account];
            // Single-division (MUDS) form — matches calculateRewardUSDC so view is consistent with state path.
            if (effectiveTotalUSDC > lastClaimed) {
                usdcReward += (accountBalance * (effectiveTotalUSDC - lastClaimed)) / totalSupply();
            }
        }

        // Subtract the already-counted calculateRewardUSDC (which used stale aggregate)
        // and avoid double-counting: we already added calculateRewardUSDC via the
        // effectiveTotalUSDC path above, so we do NOT add calculateRewardUSDC separately.
    }

    /**
     * @notice Calculates the POL reward amount owed to an account
     * @dev Uses proportional distribution based on token holdings and time since last claim.
     *      Formula: (accountBalance / totalSupply) * (currentAggregate - lastClaim)
     *
     * @param account The address to calculate rewards for
     * @return uint256 The POL reward amount in wei
     *
     * Calculation Steps:
     * 1. Get account's current token balance
     * 2. If balance is zero, return 0
     * 3. Get last claim timestamp (aggregate POL at time of last claim)
     * 4. Calculate holder's percentage of total supply (scaled by 10^18)
     * 5. Calculate new POL added since last claim
     * 6. Apply holder's percentage to new POL
     *
     * Edge Cases:
     * - Returns 0 if account has zero balance
     * - Returns 0 if total aggregate rewards are zero
     * - Returns 0 if total supply is zero (shouldn't happen)
     *
     * @custom:precision Uses 18 decimal precision for percentage calculation
     */
    function calculateRewardPOL(address account) public view returns (uint256) {
        uint256 accountTokenBalance = balanceOf(account);
        LibVoxTokenStorage.TokenStorage storage tokenStorage = LibVoxTokenStorage.tokenStorage();

        if (accountTokenBalance == 0 || tokenStorage.totalAggregateRewardInPOLWei == 0 || totalSupply() == 0) {
            return 0;
        }

        uint256 lastClaimedAtRewardAggregateInPOL = tokenStorage.lastRewardClaimInPOL[account];
        // Single-division (MUDS) form: multiply first, then divide once by totalSupply.
        // Avoids truncating small holders' share to zero when scaling by 1e18 twice.
        // Worst-case intermediate: totalSupply * totalSupply ≈ (2.1e25)^2 ≈ 4.4e50, well below type(uint256).max (~1.16e77).
        uint256 holderRewardInPol = (accountTokenBalance * (tokenStorage.totalAggregateRewardInPOLWei - lastClaimedAtRewardAggregateInPOL)) /
            totalSupply();

        return holderRewardInPol;
    }

    /**
     * @notice Calculates the USDC reward amount owed to an account
     * @dev Uses proportional distribution based on token holdings and USDC rewards from OpenAdverts.
     *      Formula: (accountBalance / totalSupply) * (currentAggregate - lastClaim)
     *
     * @param account The address to calculate rewards for
     * @return uint256 The USDC reward amount in USDC token units (6 decimals for standard USDC)
     *
     * Calculation Steps:
     * 1. Get account's current token balance
     * 2. If balance is zero, return 0
     * 3. Get last claim timestamp (aggregate USDC at time of last claim)
     * 4. Calculate holder's percentage of total supply (scaled by 10^18)
     * 5. Calculate new USDC added since last claim
     * 6. Apply holder's percentage to new USDC
     *
     * Edge Cases:
     * - Returns 0 if account has zero balance
     * - Returns 0 if total aggregate USDC rewards are zero
     * - Returns 0 if total supply is zero (shouldn't happen)
     *
     * @custom:precision Uses 18 decimal precision for percentage calculation
     * @custom:integration USDC rewards come from OpenAdverts contract
     */
    function calculateRewardUSDC(address account) public view returns (uint256) {
        uint256 accountTokenBalance = balanceOf(account);
        LibVoxTokenStorage.TokenStorage storage tokenStorage = LibVoxTokenStorage.tokenStorage();

        if (accountTokenBalance == 0 || tokenStorage.totalAggregateRewardInUSDC == 0 || totalSupply() == 0) {
            return 0;
        }

        uint256 lastClaimedAtRewardAggregateInUSDC = tokenStorage.lastRewardClaimInUSDC[account];
        // Single-division (MUDS) form. See calculateRewardPOL for rationale.
        uint256 holderRewardInUSDC = (accountTokenBalance * (tokenStorage.totalAggregateRewardInUSDC - lastClaimedAtRewardAggregateInUSDC)) /
            totalSupply();

        return holderRewardInUSDC;
    }

    // ============================================
    // FLASH LOAN PROTECTION FUNCTIONS
    // ============================================

    /**
     * @notice Records voting activity to prevent immediate re-voting
     * @dev A caller may record only their own activity (voter == msg.sender). This is an
     *      optional integration/testing hook: the built-in governance flow stamps
     *      `lastVoteBlock` directly and does NOT call this function. It only lets a caller
     *      stamp their own vote-cooldown block, so it cannot affect any other account.
     *
     * @param voter The address that performed a voting action (must be msg.sender)
     *
     * Requirements:
     * - voter must equal msg.sender (caller can only record their own activity)
     *
     * State Changes:
     * - Updates lastVoteBlock[voter] to current block
     *
     * @custom:security Uses msg.sender for access control — compatible with contract wallets
     */
    function recordVoteActivity(address voter) external {
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();
        require(voter == msg.sender, "Can only record your own voting activity");
        ts.lastVoteBlock[voter] = block.number;
    }

    /**
     * @notice Checks if an account can vote in the current block
     * @dev Implements 2-block cooldown after transfers and votes to prevent flash loan attacks.
     *
     * @param account The address to check voting eligibility for
     * @return bool True if the account can vote in this block
     *
     * Protection Rules:
     * 1. Cannot vote in same block as token transfer
     * 2. Cannot vote in same block as previous vote
     * 3. Cannot vote within 1 block after transfer (2-block total cooldown)
     * 4. Cannot vote within 1 block after voting (2-block total cooldown)
     *
     * Attack Scenarios Prevented:
     * - Flash loan attack: Borrow tokens, vote, return tokens in same tx
     * - Transfer manipulation: Receive tokens and immediately vote
     * - Vote spamming: Vote multiple times in rapid succession
     *
     * @custom:security Core flash loan protection mechanism
     */
    function canVoteThisBlock(address account) public view returns (bool) {
        return LibVoxTokenStorage.canVote(LibVoxTokenStorage.tokenStorage(), account);
    }

    /**
     * @notice Adjusts voting power when tokens are transferred
     * @dev Reduces votes proportionally across all active governance votes.
     *      Prevents vote manipulation by removing voting power when tokens leave an account.
     *
     * @param account The address whose votes should be adjusted
     * @param amount The token amount being transferred out
     *
     * Vote Adjustment Process:
     * 1. Verify amount doesn't exceed account balance
     * 2. For each admin candidate:
     *    - If user voted FOR, reduce FOR votes proportionally
     *    - If user voted AGAINST, reduce AGAINST votes proportionally
     *    - Update both user's vote record and candidate's total
     * 3. For active proposal (if user voted):
     *    - Reduce support or opposition votes proportionally
     *    - Update proposal's total vote count
     *    - If all votes removed, mark as not voted
     *
     * Proportional Reduction:
     * - If amount >= voted amount: Remove all votes
     * - If amount < voted amount: Remove proportional amount
     *
     * Requirements:
     * - Amount must not exceed account's token balance
     *
     * State Changes:
     * - Reduces adminVotesByUser for admin candidates
     * - Reduces totalVotesPerAdminCandidate
     * - Reduces votesByUser for active proposal
     * - Reduces proposal's total support/oppose votes
     * - May set hasVotedOnProposal to false if all votes removed
     *
     * @custom:security Prevents voting power manipulation via token transfers
     * @custom:fairness Maintains 1 token = 1 vote principle
     */
    function undoVotes(address account, uint256 amount) internal {
        LibVoxTokenStorage.TokenStorage storage tokenStorage = LibVoxTokenStorage.tokenStorage();
        require(amount <= tokenStorage.balances[account], "Amount exceeds account balance");

        LibVoxGovernanceStorage.GovernanceStorage storage govStorage = LibVoxGovernanceStorage.governanceStorage();

        // Short-circuit: skip the O(n) candidate loop when the account has not
        // voted in the current admin election round. This reduces the gas cost of
        // every VOX transfer during an active election for the vast majority of
        // holders, from up to 100 cold storage reads to a single bool read.
        if (govStorage.hasVotedForCandidate[account][govStorage.adminVoteId]) {
            for (uint256 i = 0; i < govStorage.proposedAdminAddresses.length; i++) {
                address adminCandidate = govStorage.proposedAdminAddresses[i];

                uint256 currentVotes = govStorage.adminVotesByUser[account][govStorage.adminVoteId][adminCandidate];

                if (currentVotes > 0) {
                    uint256 reductionAmount = amount > currentVotes ? currentVotes : amount;
                    govStorage.adminVotesByUser[account][govStorage.adminVoteId][adminCandidate] -= reductionAmount;
                    govStorage.totalVotesPerAdminCandidate[govStorage.adminVoteId][adminCandidate] -= reductionAmount;
                }
            }
        }

        if (govStorage.hasVotedOnProposal[account][govStorage.votingStruct.currentProposalId]) {
            uint256 currentSupportVotes = govStorage.votesByUser[account][govStorage.votingStruct.currentProposalId][true];
            uint256 currentOpposeVotes = govStorage.votesByUser[account][govStorage.votingStruct.currentProposalId][false];

            if (currentSupportVotes > 0) {
                uint256 reductionAmount = amount > currentSupportVotes ? currentSupportVotes : amount;
                govStorage.votesByUser[account][govStorage.votingStruct.currentProposalId][true] -= reductionAmount;
                govStorage.votingStruct.totalSupportVotesForCurrentProposal -= reductionAmount;
            } else if (currentOpposeVotes > 0) {
                uint256 reductionAmount = amount > currentOpposeVotes ? currentOpposeVotes : amount;
                govStorage.votesByUser[account][govStorage.votingStruct.currentProposalId][false] -= reductionAmount;
                govStorage.votingStruct.totalOpposeVotesForCurrentProposal -= reductionAmount;
            }

            if (
                govStorage.votesByUser[account][govStorage.votingStruct.currentProposalId][true] == 0 &&
                govStorage.votesByUser[account][govStorage.votingStruct.currentProposalId][false] == 0
            ) {
                govStorage.hasVotedOnProposal[account][govStorage.votingStruct.currentProposalId] = false;
            }
        }
    }

    // ============================================
    // VIEW FUNCTIONS (ERC20 STANDARD)
    // ============================================

    /**
     * @notice Returns the name of the token
     * @return string The token name ("Vox")
     */
    function name() public view virtual returns (string memory) {
        LibVoxTokenStorage.TokenStorage storage tokenStorage = LibVoxTokenStorage.tokenStorage();
        return tokenStorage.name;
    }

    /**
     * @notice Returns the symbol of the token
     * @return string The token symbol ("VOX")
     */
    function symbol() public view virtual returns (string memory) {
        LibVoxTokenStorage.TokenStorage storage tokenStorage = LibVoxTokenStorage.tokenStorage();
        return tokenStorage.symbol;
    }

    /**
     * @notice Returns the number of decimals used for token amounts
     * @return uint8 The number of decimals (18)
     */
    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    /**
     * @notice Returns the total token supply
     * @return uint256 The total supply of VOX tokens (21,000,000 * 10^18)
     */
    function totalSupply() public view virtual returns (uint256) {
        LibVoxTokenStorage.TokenStorage storage tokenStorage = LibVoxTokenStorage.tokenStorage();
        return tokenStorage.totalSupply;
    }

    /**
     * @notice Returns the token balance of an account
     * @param account The address to query
     * @return uint256 The account's token balance in wei (18 decimals)
     */
    function balanceOf(address account) public view virtual returns (uint256) {
        LibVoxTokenStorage.TokenStorage storage tokenStorage = LibVoxTokenStorage.tokenStorage();
        return tokenStorage.balances[account];
    }

    // ============================================
    // VIEW FUNCTIONS (REWARD & GOVERNANCE)
    // ============================================

    /**
     * @notice Returns the percentage breakdown for reward claims
     * @dev Used by external contracts to determine fund allocation.
     *      Returns dynamic array containing only non-zero third party percentages.
     *
     * @return affiliateClaimPercentage Percentage of bounty for affiliate/platform (0-100)
     * @return viewerClaimPercentage Percentage of bounty for viewer (0-100)
     * @return thirdPartyCount Number of third parties with non-zero allocations (0-6)
     * @return thirdPartyClaimPercentages Array of percentages for each third party (length == thirdPartyCount)
     *
     * Note: All percentages (affiliate + viewer + sum of third parties) must equal 100%
     */
    function getClaimPercentages()
        external
        view
        returns (
            uint256 affiliateClaimPercentage,
            uint256 viewerClaimPercentage,
            uint256 thirdPartyCount,
            uint256[] memory thirdPartyClaimPercentages
        )
    {
        LibVoxGovernanceStorage.GovernanceStorage storage govStorage = LibVoxGovernanceStorage.governanceStorage();

        // Get affiliate (vox) and viewer percentages
        affiliateClaimPercentage = govStorage.currentQuotas.voxClaimPercentage;
        viewerClaimPercentage = govStorage.currentQuotas.viewerClaimPercentage;

        // Build array of third party percentages (only non-zero)
        uint256[6] memory allThirdParties = [
            govStorage.currentQuotas.thirdParty1ClaimPercentage,
            govStorage.currentQuotas.thirdParty2ClaimPercentage,
            govStorage.currentQuotas.thirdParty3ClaimPercentage,
            govStorage.currentQuotas.thirdParty4ClaimPercentage,
            govStorage.currentQuotas.thirdParty5ClaimPercentage,
            govStorage.currentQuotas.thirdParty6ClaimPercentage
        ];

        // Count non-zero third parties
        thirdPartyCount = 0;
        for (uint256 i = 0; i < 6; i++) {
            if (allThirdParties[i] > 0) {
                thirdPartyCount++;
            }
        }

        // Build dynamic array with only non-zero values
        thirdPartyClaimPercentages = new uint256[](thirdPartyCount);
        uint256 index = 0;
        for (uint256 i = 0; i < 6; i++) {
            if (allThirdParties[i] > 0) {
                thirdPartyClaimPercentages[index] = allThirdParties[i];
                index++;
            }
        }
    }

    /**
     * @notice Returns the USDC token contract address
     * @return address The address of the USDC token contract used for rewards
     */
    function getUSDCAddress() external view returns (address) {
        LibVoxTokenStorage.TokenStorage storage tokenStorage = LibVoxTokenStorage.tokenStorage();
        return tokenStorage.usdcTokenAddress;
    }

    /**
     * @notice Returns the Chainlink price feed address
     * @return address The address of the POL/USD price feed
     */
    function getPriceFeedAddress() external view returns (address) {
        LibVoxTokenStorage.TokenStorage storage tokenStorage = LibVoxTokenStorage.tokenStorage();
        return tokenStorage.priceFeedAddress;
    }

    /**
     * @notice Returns the OpenAdverts contract address
     * @return address The address of the OpenAdverts contract
     */
    function getOpenAdvertsContractAddress() external view returns (address) {
        LibVoxTokenStorage.TokenStorage storage tokenStorage = LibVoxTokenStorage.tokenStorage();
        return tokenStorage.openAdvertsContractAddress;
    }

    /**
     * @notice Returns the total POL held by the contract
     * @return uint256 The contract's POL balance in wei
     */
    function getTotalValue() public view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @notice Returns both the total contract POL balance and caller's rewards due
     * @dev Calculates both POL and USDC rewards owed to the message sender
     * @return totalPOLValue The total POL held by the contract in wei
     * @return totalUSDCValue The total USDC held by the contract in USDC units
     * @return polRewardDue The POL reward owed to the caller in wei
     * @return usdcRewardDue The USDC reward owed to the caller in USDC units
     */
    function getTotalValueAndRewardDue()
        public
        view
        returns (uint256 totalPOLValue, uint256 totalUSDCValue, uint256 polRewardDue, uint256 usdcRewardDue)
    {
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();

        totalPOLValue = address(this).balance;
        totalUSDCValue = IERC20(ts.usdcTokenAddress).balanceOf(address(this));

        // Include both accrued unclaimed and unaccrued cursor gap
        polRewardDue = ts.unclaimedPOL[msg.sender] + calculateRewardPOL(msg.sender);
        usdcRewardDue = ts.unclaimedUSDC[msg.sender] + calculateRewardUSDC(msg.sender);
    }

    // ============================================
    // STORAGE PROVIDER FUNCTIONS (OWNER ONLY)
    // ============================================

    /**
     * @notice Returns the storage provider tranche balances
     * @dev These funds are accumulated from the storage provider percentage
     *      and are intended for offchain Turbo topup operations
     * @return polAmount POL balance available for storage provider in wei
     * @return usdcAmount USDC balance available for storage provider
     */
    function getStorageProviderTranche() external view returns (uint256 polAmount, uint256 usdcAmount) {
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();
        return (ts.storageProviderPOLBalance, ts.storageProviderUSDCBalance);
    }

    /**
     * @notice Sends the designated storage-provider tranche to the storage-provider address
     * @dev Owner-triggered, but the destination is fixed to `storageProviderAddress`
     *      (governance storage) — the owner cannot redirect these funds to themselves.
     *      The storage provider then buys Irys/Turbo credits offchain; the owner may record
     *      it via confirmTurboTopup(). Emits an event for transparency.
     *
     *      Note: the tranche is held in the Diamond and only tracked by
     *      `storageProviderPOLBalance` / `storageProviderUSDCBalance`; this call is what
     *      actually moves it out to the storage-provider address.
     *
     * @param polAmount Amount of POL to send in wei
     * @param usdcAmount Amount of USDC to send
     *
     * Requirements:
     * - Caller must be contract owner
     * - `storageProviderAddress` must be set
     * - Sufficient designated balance must be available
     *
     * Emits: StorageProviderWithdrawal event (first arg is the recipient storage-provider address)
     */
    function withdrawStorageProviderFunds(uint256 polAmount, uint256 usdcAmount) external nonReentrant {
        LibDiamond.enforceIsContractOwner();
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();
        address storageProvider = LibVoxGovernanceStorage.governanceStorage().storageProviderAddress;
        require(storageProvider != address(0), "Storage provider not set");

        // Reconcile any pending USDC deposits first, so the tranche and the deposit
        // watermark are current before funds move out.
        processNewUSDCDeposits();

        require(polAmount <= ts.storageProviderPOLBalance, "Insufficient POL balance");
        require(usdcAmount <= ts.storageProviderUSDCBalance, "Insufficient USDC balance");

        // Update balances
        if (polAmount > 0) {
            ts.storageProviderPOLBalance -= polAmount;
            (bool success, ) = payable(storageProvider).call{value: polAmount}("");
            require(success, "POL transfer failed");
        }

        if (usdcAmount > 0) {
            ts.storageProviderUSDCBalance -= usdcAmount;
            IERC20(ts.usdcTokenAddress).safeTransfer(storageProvider, usdcAmount);
            // Advance the deposit-detection watermark after USDC leaves the contract;
            // otherwise future USDC deposits are under-counted by the withdrawn amount.
            ts.lastKnownUSDCBalance = IERC20(ts.usdcTokenAddress).balanceOf(address(this));
        }

        emit StorageProviderWithdrawal(storageProvider, polAmount, usdcAmount, block.timestamp);
    }

    /**
     * @notice Records confirmation of offchain Turbo topup execution
     * @dev Voluntary transparency function for owner to report topup execution.
     *      Creates audit trail for community monitoring. Records transaction ID
     *      and details for historical tracking.
     *
     * @param transactionId Turbo transaction ID from offchain topup
     * @param polAmount Amount of POL topped up
     * @param usdcAmount Amount of USDC topped up
     *
     * Requirements:
     * - Caller must be contract owner
     * - Transaction ID must not be empty
     * - Transaction ID must be unique (not previously recorded)
     *
     * Emits: TurboTopupConfirmed event
     */
    function confirmTurboTopup(string memory transactionId, uint256 polAmount, uint256 usdcAmount) external {
        LibDiamond.enforceIsContractOwner();
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();

        require(bytes(transactionId).length > 0, "Transaction ID cannot be empty");
        require(ts.turboTopupRecords[transactionId].timestamp == 0, "Transaction ID already recorded");

        // Record the topup
        ts.turboTopupTransactionIds.push(transactionId);
        ts.turboTopupRecords[transactionId] = LibVoxTokenStorage.TurboTopupRecord({
            polAmount: polAmount,
            usdcAmount: usdcAmount,
            timestamp: block.timestamp,
            executedBy: msg.sender
        });

        emit TurboTopupConfirmed(transactionId, polAmount, usdcAmount, block.timestamp);
    }

    /**
     * @notice Returns all recorded Turbo topup transaction IDs
     * @dev Useful for auditing and tracking historical topups
     * @return Array of transaction ID strings
     */
    function getTurboTopupHistory() external view returns (string[] memory) {
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();
        return ts.turboTopupTransactionIds;
    }

    /**
     * @notice Returns details of a specific Turbo topup transaction
     * @param transactionId The transaction ID to query
     * @return polAmount Amount of POL topped up
     * @return usdcAmount Amount of USDC topped up
     * @return timestamp When the topup was recorded
     * @return executedBy Address that executed the topup
     */
    function getTurboTopupDetails(
        string memory transactionId
    ) external view returns (uint256 polAmount, uint256 usdcAmount, uint256 timestamp, address executedBy) {
        LibVoxTokenStorage.TokenStorage storage ts = LibVoxTokenStorage.tokenStorage();
        LibVoxTokenStorage.TurboTopupRecord storage record = ts.turboTopupRecords[transactionId];

        return (record.polAmount, record.usdcAmount, record.timestamp, record.executedBy);
    }

    // ============================================
    // EVENTS
    // ============================================

    /**
     * @notice Emitted when storage provider funds are withdrawn
     * @param withdrawer Address that withdrew (always owner)
     * @param polAmount POL amount withdrawn
     * @param usdcAmount USDC amount withdrawn
     * @param timestamp When the withdrawal occurred
     */
    event StorageProviderWithdrawal(address indexed withdrawer, uint256 polAmount, uint256 usdcAmount, uint256 timestamp);

    /**
     * @notice Emitted when owner confirms offchain Turbo topup execution
     * @param transactionId Turbo transaction ID
     * @param polAmount POL amount topped up
     * @param usdcAmount USDC amount topped up
     * @param timestamp When the confirmation was recorded
     */
    event TurboTopupConfirmed(string indexed transactionId, uint256 polAmount, uint256 usdcAmount, uint256 timestamp);

    /**
     * @notice Receive function to handle edge case of direct payments to facet address
     * @dev This only executes when POL is sent directly to facet contract address.
     *      When POL is sent to Diamond address, Diamond.sol's receive() handles it.
     *      This forwards any accidental/direct payments to the Diamond for proper processing.
     */
    receive() external payable {
        if (msg.value > 0) {
            require(diamondAddressForDirectCalls != address(0), "Diamond address not set");

            (bool success, ) = payable(diamondAddressForDirectCalls).call{value: msg.value}("");
            require(success, "Transfer to Diamond failed");
        }
    }
}
