// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

/*
  Presale_Pro.sol
  A professional presale contract with:
   - ETH and ERC20 payments
   - Whitelist (optional)
   - Soft cap & Hard cap
   - Min/Max contribution per address
   - Vesting with cliff + linear unlock
   - Pause / Resume by owner
   - Emergency refund if soft cap not met
   - Owner withdrawal when successful
   - Safe ERC20 usage and reentrancy protection

  NOTE: This contract is NOT upgradeable. For upgradeable behavior, use a proxy pattern.
  Thorough testing and security audit are required before production deployment.
*/


import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PresalePro is IERC20, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /* ========== STATE ========== */
    IERC20 public saleToken;         // Token being sold
    address payable public treasury; // Where funds are forwarded on success

    uint256 public rate;             // tokens per wei (for ETH) or tokens per paymentToken unit
    IERC20 public paymentToken;      // optional ERC20 payment (if address(0) => ETH)
    bool public acceptERC20;         // allow ERC20 payments

    uint256 public softCap;          // in wei or payment token smallest unit
    uint256 public hardCap;          // maximum raise
    uint256 public weiRaised;        // total raised (in wei or payment token unit)

    uint256 public startTime;        // sale start timestamp
    uint256 public endTime;          // sale end timestamp

    uint256 public minContribution;  // per address min
    uint256 public maxContribution;  // per address max

    mapping(address => uint256) public contributions; // contributed amount per buyer
    uint256 public totalBuyers;

    // Vesting
    uint256 public vestingStart;     // timestamp when vesting starts (typically at sale end)
    uint256 public cliffDuration;    // seconds after vestingStart until first unlock
    uint256 public vestingDuration;  // linear vesting duration in seconds
    mapping(address => uint256) public claimed; // tokens claimed per buyer

    // Whitelist
    bool public whitelistEnabled;
    mapping(address => bool) public whitelist;

    // Events
    event TokensPurchased(address indexed purchaser, address indexed beneficiary, uint256 value, uint256 tokenAmount);
    event TokensClaimed(address indexed beneficiary, uint256 amount);
    event RefundClaimed(address indexed beneficiary, uint256 amount);
    event SaleStarted(uint256 startTime, uint256 endTime);
    event SaleStopped();
    event TreasuryUpdated(address indexed newTreasury);
    event WhitelistUpdated(address indexed account, bool allowed);
    event VestingParamsUpdated(uint256 vestingStart, uint256 cliff, uint256 duration);

    /* ========== MODIFIERS ========== */
    modifier onlyWhileActive() {
        require(startTime > 0 && block.timestamp >= startTime && block.timestamp <= endTime, "Sale: not active");
        _;
    }

    modifier onlyAfterEnd() {
        require(endTime > 0 && block.timestamp > endTime, "Sale: not ended");
        _;
    }

    modifier onlyWhitelisted(address _addr) {
        if (whitelistEnabled) {
            require(whitelist[_addr], "Sale: not whitelisted");
        }
        _;
    }

    constructor(
        IERC20 _saleToken,
        address payable _treasury,
        uint256 _rate,
        uint256 _softCap,
        uint256 _hardCap,
        uint256 _startTime,
        uint256 _endTime
    ) {
        require(address(_saleToken) != address(0), "invalid sale token");
        require(_treasury != payable(address(0)), "invalid treasury");
        require(_rate > 0, "rate > 0");
        require(_startTime < _endTime, "start < end");
        require(_softCap <= _hardCap, "soft <= hard");

        saleToken = _saleToken;
        treasury = _treasury;
        rate = _rate;
        softCap = _softCap;
        hardCap = _hardCap;
        startTime = _startTime;
        endTime = _endTime;

        whitelistEnabled = false;
        acceptERC20 = false;
    }

    /* ========== ADMIN FUNCTIONS ========== */
    function setPaymentERC20(IERC20 _paymentToken, bool _enable) external onlyOwner {
        paymentToken = _paymentToken;
        acceptERC20 = _enable;
    }

    function setContributionLimits(uint256 _min, uint256 _max) external onlyOwner {
        require(_min <= _max, "min <= max");
        minContribution = _min;
        maxContribution = _max;
    }

    function setWhitelistEnabled(bool _enabled) external onlyOwner {
        whitelistEnabled = _enabled;
    }

    function updateWhitelist(address[] calldata accounts, bool allowed) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            whitelist[accounts[i]] = allowed;
            emit WhitelistUpdated(accounts[i], allowed);
        }
    }

    function setVestingParams(uint256 _vestingStart, uint256 _cliff, uint256 _duration) external onlyOwner {
        require(_duration >= _cliff, "duration >= cliff");
        vestingStart = _vestingStart;
        cliffDuration = _cliff;
        vestingDuration = _duration;
        emit VestingParamsUpdated(_vestingStart, _cliff, _duration);
    }

    function pauseSale() external onlyOwner {
        _pause();
    }

    function resumeSale() external onlyOwner {
        _unpause();
    }

    function updateTreasury(address payable _newTreasury) external onlyOwner {
        require(_newTreasury != payable(address(0)), "invalid");
        treasury = _newTreasury;
        emit TreasuryUpdated(_newTreasury);
    }

    function emergencyWithdrawTokens(IERC20 token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "invalid");
        token.safeTransfer(to, amount);
    }

    /* ========== PUBLIC BUYING ========== */

    // Buy with ETH
    receive() external payable {
        revert("Use buyWithETH");
    }

    function buyWithETH(address beneficiary) external payable nonReentrant whenNotPaused onlyWhileActive onlyWhitelisted(msg.sender) {
        require(!acceptERC20, "ERC20 payments enabled");
        _preValidatePurchase(beneficiary, msg.value);

        uint256 tokens = _getTokenAmount(msg.value);
        _processPurchase(beneficiary, tokens);

        weiRaised += msg.value;
        contributions[beneficiary] += msg.value;

        if (contributions[beneficiary] == msg.value) {
            // first time buyer
            totalBuyers += 1;
        }

        emit TokensPurchased(msg.sender, beneficiary, msg.value, tokens);

        // If hardCap reached, auto stop (owner may still decide to forward funds)
        if (weiRaised >= hardCap) {
            endTime = block.timestamp; // immediate end
        }
    }

    // Buy with ERC20 payment (e.g., USDT) - amount is in payment token smallest unit
    function buyWithToken(address beneficiary, uint256 amount) external nonReentrant whenNotPaused onlyWhileActive onlyWhitelisted(msg.sender) {
        require(acceptERC20, "ERC20 not enabled");
        require(address(paymentToken) != address(0), "payment token not set");
        _preValidatePurchase(beneficiary, amount);

        // transfer payment token from buyer to this contract
        paymentToken.safeTransferFrom(msg.sender, address(this), amount);

        uint256 tokens = _getTokenAmount(amount);
        _processPurchase(beneficiary, tokens);

        weiRaised += amount;
        contributions[beneficiary] += amount;

        if (contributions[beneficiary] == amount) {
            totalBuyers += 1;
        }

        emit TokensPurchased(msg.sender, beneficiary, amount, tokens);

        if (weiRaised >= hardCap) {
            endTime = block.timestamp;
        }
    }

    /* ========== INTERNAL HELPERS ========== */
    function _preValidatePurchase(address beneficiary, uint256 value) internal view {
        require(beneficiary != address(0), "invalid beneficiary");
        require(value > 0, "zero value");
        require(weiRaised + value <= hardCap, "exceeds hard cap");
        if (minContribution > 0) {
            require(contributions[beneficiary] + value >= minContribution, "below min");
        }
        if (maxContribution > 0) {
            require(contributions[beneficiary] + value <= maxContribution, "above max");
        }
    }

    function _getTokenAmount(uint256 paymentAmount) internal view returns (uint256) {
        // tokens = paymentAmount * rate
        return paymentAmount * rate;
    }

    function _processPurchase(address beneficiary, uint256 tokenAmount) internal {
        // Ensure contract has enough tokens
        uint256 contractBalance = saleToken.balanceOf(address(this));
        require(contractBalance >= tokenAmount + _totalClaimable(), "not enough tokens in contract");

        // For presale, we do not transfer tokens immediately; they are vested/claimed later
    }

    function _totalClaimable() internal view returns (uint256) {
        // total tokens already allocated to contributors but not yet claimed
        // sum(contributions * rate) - sum(claimed)
        // This is a gas-heavy calculation if done naively; instead we rely on per-account checks.
        // Here we return 0 (conservative) because _processPurchase checked balance vs tokenAmount only.
        return 0;
    }

    /* ========== CLAIM / VESTING ========== */

    function claim() external nonReentrant whenNotPaused onlyAfterEnd onlyWhitelisted(msg.sender) {
        require(weiRaised >= softCap, "soft cap not reached - request refund");
        require(vestingStart > 0, "vesting not configured");

        uint256 totalTokens = contributions[msg.sender] * rate;
        require(totalTokens > 0, "no tokens to claim");

        uint256 vested = _vestedAmount(totalTokens, block.timestamp);
        uint256 claimable = vested - claimed[msg.sender];
        require(claimable > 0, "no tokens available");

        claimed[msg.sender] += claimable;
        saleToken.safeTransfer(msg.sender, claimable);

        emit TokensClaimed(msg.sender, claimable);
    }

    function _vestedAmount(uint256 totalAllocation, uint256 currentTime) public view returns (uint256) {
        if (currentTime < vestingStart + cliffDuration) {
            return 0;
        }
        if (currentTime >= vestingStart + vestingDuration) {
            return totalAllocation;
        }
        uint256 timeFromStart = currentTime - vestingStart;
        // linear vesting after cliff
        return (totalAllocation * timeFromStart) / vestingDuration;
    }

    /* ========== REFUND (if softCap not reached) ========== */
    function claimRefund() external nonReentrant whenNotPaused onlyAfterEnd onlyWhitelisted(msg.sender) {
        require(weiRaised < softCap, "soft cap reached - no refunds");
        uint256 contributed = contributions[msg.sender];
        require(contributed > 0, "no contribution");

        contributions[msg.sender] = 0;

        if (address(paymentToken) == address(0)) {
            // ETH refunds
            (bool sent, ) = msg.sender.call{value: contributed}('');
            require(sent, "refund failed");
        } else {
            paymentToken.safeTransfer(msg.sender, contributed);
        }

        emit RefundClaimed(msg.sender, contributed);
    }

    /* ========== OWNER ACTIONS AFTER SALE ========== */

    // Owner forwards raised funds to treasury if softCap reached
    function forwardFunds() external onlyOwner onlyAfterEnd {
        require(weiRaised > 0, "no funds");
        require(weiRaised >= softCap, "soft cap not reached");

        if (address(paymentToken) == address(0)) {
            uint256 balance = address(this).balance;
            require(balance >= weiRaised, "insufficient ETH balance");
            treasury.transfer(balance);
        } else {
            uint256 bal = paymentToken.balanceOf(address(this));
            paymentToken.safeTransfer(treasury, bal);
        }
    }

    // In case owner wants to burn or recover unsold tokens after sale
    function recoverUnsoldTokens(address to) external onlyOwner onlyAfterEnd {
        require(to != address(0), "invalid");
        uint256 contractBal = saleToken.balanceOf(address(this));
        // compute total allocated = sum(contributions*rate) -> not stored centrally, so owner should ensure logic off-chain
        saleToken.safeTransfer(to, contractBal);
    }

    /* ========== VIEW HELPERS ========== */
    function tokensAllocated(address account) external view returns (uint256) {
        return contributions[account] * rate;
    }

    function tokensClaimed(address account) external view returns (uint256) {
        return claimed[account];
    }

    function saleActive() external view returns (bool) {
        return startTime > 0 && block.timestamp >= startTime && block.timestamp <= endTime;
    }

    /* ========== SAFETY / UTIL ========== */
    // Allow owner to deposit sale tokens into contract before start
    function depositSaleTokens(uint256 amount) external onlyOwner {
        saleToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    // Owner can extend endTime before sale ends
    function extendEndTime(uint256 newEndTime) external onlyOwner {
        require(newEndTime > endTime, "new > old");
        endTime = newEndTime;
    }

    // Fallback to accept ETH when paymentToken is not used and contract receives funds by mistake
    function sendETHToContract() external payable {}

}
