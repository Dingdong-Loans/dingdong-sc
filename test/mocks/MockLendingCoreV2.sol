// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.27;

import {AccessControlUpgradeable} from "@openzeppelin-upgradeable/contracts/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/contracts/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ICollateralManager} from "../../src/core/interfaces/ICollateralManager.sol";
import {IInterestRateModel} from "../../src/core/interfaces/IInterestRateModel.sol";
import {IPriceOracle} from "../../src/core/interfaces/IPriceOracle.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev delete this! testing only
import {console} from "forge-std/console.sol";

contract MockLendingCoreV2 is
    Initializable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20Metadata;

    // ========== EVENTS ==========
    event BorrowTokenAdded(address indexed manager, address indexed token);
    event BorrowTokenRemoved(address indexed manager, address indexed token);
    event CollateralTokenAdded(address indexed manager, address indexed token);
    event CollateralTokenRemoved(address indexed manager, address indexed token);
    event SupplyAdded(address indexed provider, address indexed token, uint256 amount);
    event SupplyRemoved(address indexed withdrawer, address indexed token, uint256 amount);
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed user, address indexed token, uint256 amount);
    event Borrowed(address indexed user, address indexed token, uint256 amount, address indexed collateral);
    event Repaid(address indexed user, address indexed token, uint256 amount);
    event Liquidated(address indexed user, address indexed token, uint256 seizedAmount);

    // ========== ERRORS ==========
    error LendingCore__InvalidAddress();
    error LendingCore__CollateralManagerAlreadySet();
    error LendingCore__MathOverflow();
    error LendingCore__ZeroAmountNotAllowed();
    error LendingCore__AmountExceedsLimit(uint256 max, uint256 attempted);
    error LendingCore__DurationExceedsLimit(uint256 max, uint256 attemted);
    error LendingCore__InsufficientBalance(address token, uint256 available);
    error LendingCore__LoanIsActive();
    error LendingCore__LoanIsInactive();
    error LendingCore__UnsupportedToken(address token);
    error LendingCore__NotLiquidateable();

    // ========== TYPE DECLARATIONS ==========
    struct Loan {
        uint256 principal;
        uint256 interestAccrued;
        uint256 repaidAmount;
        uint256 totalLiquidated;
        address borrowToken;
        uint40 startTime;
        uint40 dueDate;
        bool active;
    }

    // ========== ROLES ==========
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PARAMETER_MANAGER_ROLE = keccak256("PARAMETER_MANAGER_ROLE");
    bytes32 public constant TOKEN_MANAGER_ROLE = keccak256("TOKEN_MANAGER_ROLE");
    bytes32 public constant LIQUIDITY_PROVIDER_ROLE = keccak256("LIQUIDITY_PROVIDER_ROLE");
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");

    // ========== CONSTANTS ==========
    uint16 public constant BPS_DENOMINATOR = 10000;

    // ========== MODULES ==========
    /// @dev collateralManager contain user balance state, therefore should be immutable
    ICollateralManager public s_collateralManager;
    IInterestRateModel public s_interestRateModel;
    IPriceOracle public s_priceOracle;

    // ========== STORAGES ==========
    // Loan parameter (not set by default)
    uint40 public s_maxBorrowDuration;
    uint40 public s_gracePeriod;
    mapping(address => uint16) public s_ltvBPS;
    mapping(address => uint16) public s_liquidationPenaltyBPS;

    // Protocol information
    address[] public s_borrowTokens;
    // mapping(address => uint8) public s_borrowTokenDecimals;
    mapping(address => bool) public s_isBorrowTokenSupported;
    mapping(address => uint256) public s_totalDebt;
    mapping(address => mapping(address => Loan)) public s_userLoans;
    mapping(address => uint256) public s_liquidatedCollateral;

    // KYC restriction(unimplemented)
    // mapping(address => bool) public s_isKYCed;

    uint256 num;

    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address defaultAdmin, address[6] calldata role) public initializer {
        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(PAUSER_ROLE, role[0]);
        _grantRole(UPGRADER_ROLE, role[1]);
        _grantRole(PARAMETER_MANAGER_ROLE, role[2]);
        _grantRole(TOKEN_MANAGER_ROLE, role[3]);
        _grantRole(LIQUIDITY_PROVIDER_ROLE, role[4]);
        _grantRole(LIQUIDATOR_ROLE, role[5]);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // ========== MAIN FUNCTIONS ==========

    function setNum(uint256 _num) public {
        num = _num;
    }

    function getNum() public view returns (uint256) {
        return num;
    }

    /**
     * @notice deposit collateral to protocol
     * @param _token address of token to deposit
     * @param _amount amount to deposit
     */
    function depositCollateral(address _token, uint256 _amount) external nonReentrant whenNotPaused {
        require(_token != address(0), LendingCore__InvalidAddress());
        require(_amount > 0, LendingCore__ZeroAmountNotAllowed());
        require(s_collateralManager.s_isCollateralTokenSupported(_token), LendingCore__UnsupportedToken(_token));

        IERC20Metadata(_token).safeTransferFrom(msg.sender, address(this), _amount);
        s_collateralManager.deposit(msg.sender, _token, _amount);

        emit CollateralDeposited(msg.sender, _token, _amount);
    }

    /**
     * @notice withdraw collateral to protocol
     * @param _token address of token to withdraw
     * @param _amount amount to withdraw
     */
    function withdrawCollateral(address _token, uint256 _amount) external nonReentrant whenNotPaused {
        uint256 depositedCollateral = s_collateralManager.getDepositedCollateral(msg.sender, _token);

        require(_token != address(0), LendingCore__InvalidAddress());
        require(_amount > 0, LendingCore__ZeroAmountNotAllowed());
        require(s_collateralManager.s_isCollateralTokenSupported(_token), LendingCore__UnsupportedToken(_token));
        require(depositedCollateral >= _amount, LendingCore__AmountExceedsLimit(depositedCollateral, _amount));

        s_collateralManager.withdraw(msg.sender, _token, _amount);
        console.log("here");
        require(_getHealthFactor(msg.sender, _token) >= BPS_DENOMINATOR, LendingCore__LoanIsActive());
        console.log("here2");

        IERC20Metadata(_token).safeTransfer(msg.sender, _amount);

        emit CollateralWithdrawn(msg.sender, _token, _amount);
    }

    /**
     * @notice borrow token of choice
     * @param _borrowToken the address of token to borrow
     * @param _amount the amount to borrow
     * @param _collateralToken the address of collateral token
     * @param _duration the borrow duration
     */
    function borrow(address _borrowToken, uint256 _amount, address _collateralToken, uint64 _duration)
        external
        nonReentrant
        whenNotPaused
    {
        require(_borrowToken != address(0) && _collateralToken != address(0), LendingCore__InvalidAddress());
        require(_amount > 0 && _duration >= 1 days, LendingCore__ZeroAmountNotAllowed());
        require(
            s_collateralManager.s_isCollateralTokenSupported(_collateralToken),
            LendingCore__UnsupportedToken(_collateralToken)
        );
        require(s_isBorrowTokenSupported[_borrowToken], LendingCore__UnsupportedToken(_borrowToken));

        uint256 maxBorrowDuration = s_maxBorrowDuration;
        uint256 availableLiquidity = IERC20Metadata(_borrowToken).balanceOf(address(this));

        // require(_getTotalTokenValueInUsd(msg.sender, _collateralToken) > 0, LendingCore__InsufficientBalance());
        require(availableLiquidity >= _amount, LendingCore__InsufficientBalance(_borrowToken, availableLiquidity));
        require(_duration <= maxBorrowDuration, LendingCore__DurationExceedsLimit(maxBorrowDuration, _duration));

        Loan storage userLoan = s_userLoans[msg.sender][_collateralToken];
        require(!userLoan.active, LendingCore__LoanIsActive());

        uint256 interestRateBPS = s_interestRateModel.getBorrowRateBPS(_duration, getUtilizationBPS(_borrowToken));

        uint256 maxBorrowAfterInterest = Math.mulDiv(
            getMaxBorrowBeforeInterest(msg.sender, _borrowToken, _collateralToken),
            BPS_DENOMINATOR,
            BPS_DENOMINATOR + interestRateBPS
        );

        require(_amount <= maxBorrowAfterInterest, LendingCore__AmountExceedsLimit(maxBorrowAfterInterest, _amount));

        uint256 interestAmount = Math.mulDiv(_amount, interestRateBPS, BPS_DENOMINATOR);

        userLoan.borrowToken = _borrowToken;
        userLoan.principal = _amount;
        userLoan.interestAccrued = interestAmount;
        userLoan.startTime = uint40(block.timestamp);
        /// @dev no check for time exploit yet
        userLoan.dueDate = uint40(block.timestamp + _duration);
        userLoan.active = true;

        s_totalDebt[_borrowToken] += (_amount + interestAmount);

        IERC20Metadata(_borrowToken).safeTransfer(msg.sender, _amount);

        emit Borrowed(msg.sender, _borrowToken, _amount, _collateralToken);
    }

    /**
     * @notice repay borrowed token
     * @param _collateralToken address of collateral token used as collateral on a loan
     * @param _amount amount to be repayed
     */
    function repay(address _collateralToken, uint256 _amount) external nonReentrant whenNotPaused {
        require(_collateralToken != address(0), LendingCore__InvalidAddress());
        require(_amount > 0, LendingCore__ZeroAmountNotAllowed());
        require(
            s_collateralManager.s_isCollateralTokenSupported(_collateralToken),
            LendingCore__UnsupportedToken(_collateralToken)
        );

        Loan storage userLoan = s_userLoans[msg.sender][_collateralToken];
        require(userLoan.active, LendingCore__LoanIsInactive());

        address borrowToken = userLoan.borrowToken;

        uint256 remainingDebt = userLoan.principal + userLoan.interestAccrued - userLoan.repaidAmount;

        require(_amount <= remainingDebt, LendingCore__AmountExceedsLimit(remainingDebt, _amount));
        // require(s_totalDebt[borrowToken] >= _amount, "Internal borrow tracking underflow");

        IERC20Metadata(borrowToken).safeTransferFrom(msg.sender, address(this), _amount);

        userLoan.repaidAmount += _amount;
        s_totalDebt[borrowToken] -= _amount;

        if (userLoan.repaidAmount == (userLoan.principal + userLoan.interestAccrued)) {
            delete s_userLoans[msg.sender][_collateralToken];
        }

        emit Repaid(msg.sender, _collateralToken, _amount);
    }

    // ========== LIQUIDATOR_ROLE FUNCTIONS ==========
    /**
     * @notice liquidate undercollateralized user
     * @param _user the address of user to liquidate
     * @param _collateralToken the address of collateral token to liquidate
     */
    function liquidate(address _user, address _collateralToken) external onlyRole(LIQUIDATOR_ROLE) nonReentrant {
        Loan memory userLoan = s_userLoans[_user][_collateralToken];

        require(_user != address(0) && _collateralToken != address(0), LendingCore__InvalidAddress());
        require(
            s_collateralManager.s_isCollateralTokenSupported(_collateralToken),
            LendingCore__UnsupportedToken(_collateralToken)
        );

        require(
            _getHealthFactor(_user, _collateralToken) < BPS_DENOMINATOR || userLoan.dueDate < block.timestamp,
            LendingCore__NotLiquidateable()
        );

        address borrowToken = userLoan.borrowToken;
        uint256 totalDebt = userLoan.principal + userLoan.interestAccrued;
        require(userLoan.active && totalDebt > userLoan.repaidAmount, LendingCore__LoanIsInactive());

        uint256 remainingDebt = totalDebt - userLoan.repaidAmount;
        uint256 userDebtUsd = s_priceOracle.getValue(borrowToken, remainingDebt);

        uint256 repayAmountUsd;
        uint256 repayTokenAmount;

        {
            uint256 denominator = Math.mulDiv(
                s_ltvBPS[_collateralToken], BPS_DENOMINATOR + s_liquidationPenaltyBPS[_collateralToken], BPS_DENOMINATOR
            );
            repayAmountUsd = Math.mulDiv(userDebtUsd, BPS_DENOMINATOR, denominator);
            if (repayAmountUsd > userDebtUsd) {
                repayAmountUsd = userDebtUsd;
            }
            repayTokenAmount = _usdToTokenAmount(repayAmountUsd, userLoan.borrowToken);
        }

        if (repayTokenAmount > remainingDebt) repayTokenAmount = remainingDebt;

        require(s_totalDebt[borrowToken] >= repayTokenAmount, LendingCore__MathOverflow());

        uint256 seizeAmount;
        {
            uint256 penaltyUsd = Math.mulDiv(repayAmountUsd, s_liquidationPenaltyBPS[_collateralToken], BPS_DENOMINATOR);
            uint256 totalSeizeUsd = repayAmountUsd + penaltyUsd;

            seizeAmount = _usdToTokenAmount(totalSeizeUsd, _collateralToken);
            uint256 collateralBalance = s_collateralManager.getDepositedCollateral(_user, _collateralToken);

            if (seizeAmount > collateralBalance) {
                seizeAmount = collateralBalance;
                totalSeizeUsd = s_priceOracle.getValue(_collateralToken, seizeAmount);
                repayAmountUsd = totalSeizeUsd - penaltyUsd;
                repayTokenAmount = _usdToTokenAmount(repayAmountUsd, borrowToken);
            }
        }

        if (s_userLoans[_user][_collateralToken].repaidAmount >= totalDebt) {
            // or just set the loan as inactive
            delete s_userLoans[_user][_collateralToken];
        }

        s_totalDebt[borrowToken] -= repayTokenAmount;
        s_userLoans[_user][_collateralToken].repaidAmount += repayTokenAmount;
        s_userLoans[_user][_collateralToken].totalLiquidated += seizeAmount;
        s_liquidatedCollateral[_collateralToken] += seizeAmount;
        s_collateralManager.withdraw(_user, _collateralToken, seizeAmount);

        emit Liquidated(_user, _collateralToken, seizeAmount);
    }

    // ========== LIQUIDITY_PROVIDER_ROLE FUNCTIONS ==========
    /**
     * @notice Add liquidity of specific token
     * @param _token address of borrow token
     * @param _amount amount of liquidity to add
     */
    function addLiquidity(address _token, uint256 _amount) external onlyRole(LIQUIDITY_PROVIDER_ROLE) nonReentrant {
        require(s_isBorrowTokenSupported[_token], LendingCore__UnsupportedToken(_token));
        require(_token != address(0), LendingCore__InvalidAddress());
        require(_amount > 0, LendingCore__ZeroAmountNotAllowed());

        IERC20Metadata(_token).safeTransferFrom(msg.sender, address(this), _amount);
        emit SupplyAdded(_token, msg.sender, _amount);
    }

    /**
     * @notice remove liquidity of specific token
     * @param _token address of borrow token
     * @param _amount amount of liquidity to remove
     */
    function removeLiquidity(address _token, uint256 _amount) external onlyRole(LIQUIDITY_PROVIDER_ROLE) nonReentrant {
        uint256 availableLiquidity = IERC20Metadata(_token).balanceOf(address(this));

        require(s_isBorrowTokenSupported[_token], LendingCore__UnsupportedToken(_token));
        require(_token != address(0), LendingCore__InvalidAddress());
        require(_amount > 0, LendingCore__ZeroAmountNotAllowed());
        require(availableLiquidity >= _amount, LendingCore__InsufficientBalance(_token, availableLiquidity));

        IERC20Metadata(_token).safeTransfer(msg.sender, _amount);
        emit SupplyRemoved(_token, msg.sender, _amount);
    }

    function withdrawLiquidatedCollateral(address _collateralToken, uint256 _amount)
        external
        onlyRole(LIQUIDITY_PROVIDER_ROLE)
    {
        uint256 availableAmount = s_liquidatedCollateral[_collateralToken];

        require(
            s_collateralManager.s_isCollateralTokenSupported(_collateralToken),
            LendingCore__UnsupportedToken(_collateralToken)
        );
        require(_collateralToken != address(0), LendingCore__InvalidAddress());
        require(_amount > 0, LendingCore__ZeroAmountNotAllowed());
        require(availableAmount >= _amount, LendingCore__InsufficientBalance(_collateralToken, availableAmount));

        IERC20Metadata(_collateralToken).safeTransfer(msg.sender, _amount);
    }

    // ========== PARAMETER_MANAGER_ROLE FUNCTIONS ==========
    /**
     * @notice set collateral token LTV
     * @param _token the address of collateral token
     * @param _ltvBps the LTV Ratio in Basis Points
     */
    function setLTV(address _token, uint16 _ltvBps) external onlyRole(PARAMETER_MANAGER_ROLE) {
        require(_token != address(0), LendingCore__InvalidAddress());
        require(_ltvBps > 0, LendingCore__ZeroAmountNotAllowed());
        require(_ltvBps <= BPS_DENOMINATOR, LendingCore__AmountExceedsLimit(BPS_DENOMINATOR, _ltvBps));

        s_ltvBPS[_token] = _ltvBps;
    }

    /**
     * @notice set collateral token liquidation penalty
     * @param _token the address of collateral token
     * @param _penaltyBps the penalty amount in Basis Points
     */
    function setLiquidationPenalty(address _token, uint16 _penaltyBps) external onlyRole(PARAMETER_MANAGER_ROLE) {
        s_liquidationPenaltyBPS[_token] = _penaltyBps;
    }

    /**
     * @notice set maximum borrow duration
     * @param _duration the duration in seconds
     */
    function setMaxBorrowDuration(uint40 _duration) external onlyRole(PARAMETER_MANAGER_ROLE) {
        s_maxBorrowDuration = _duration;
    }

    /**
     * @notice set grace period
     * @param _period the period duration in seconds
     */
    function setGracePeriod(uint40 _period) external onlyRole(PARAMETER_MANAGER_ROLE) {
        s_gracePeriod = _period;
    }

    // ========== TOKEN_MANAGER_ROLE FUNCTIONS ==========
    /**
     * @notice list new borrow token
     * @param _token address of borrow token to add
     * @param _priceFeed address of borrow token pricefeed
     */
    function addBorrowToken(address _token, address _priceFeed) external onlyRole(TOKEN_MANAGER_ROLE) nonReentrant {
        s_priceOracle.setPriceFeed(_token, _priceFeed);
        /// @dev use try catch
        s_borrowTokens.push(_token);
        s_isBorrowTokenSupported[_token] = true;

        emit BorrowTokenAdded(_token, msg.sender);
    }

    /**
     * @notice remove borrow token from list
     * @param _token address of borrow token to remove
     * @dev currently does not remove associated oracle
     */
    function removeBorrowToken(address _token) external onlyRole(TOKEN_MANAGER_ROLE) nonReentrant {
        uint256 length = s_borrowTokens.length;
        for (uint256 i = 0; i < length;) {
            if (s_borrowTokens[i] == _token) {
                s_borrowTokens[i] = s_borrowTokens[length - 1];
                s_borrowTokens.pop();

                unchecked {
                    i++;
                }

                break;
            }
        }

        s_isBorrowTokenSupported[_token] = false;
        emit BorrowTokenRemoved(_token, msg.sender);
    }

    /**
     * @notice list new collateral token
     * @param _token address of collateral token to add
     * @param _priceFeed address of collateral token pricefeed
     */
    function addCollateralToken(address _token, address _priceFeed)
        external
        onlyRole(TOKEN_MANAGER_ROLE)
        nonReentrant
    {
        s_collateralManager.addCollateralToken(_token);
        s_priceOracle.setPriceFeed(_token, _priceFeed);

        emit CollateralTokenAdded(msg.sender, _token);
    }

    /**
     * @notice remove collateral token from list
     * @param _token address of collateral token to remove
     * @dev currently does not remove associated oracle
     */
    function removeCollateralToken(address _token) external onlyRole(TOKEN_MANAGER_ROLE) nonReentrant {
        s_collateralManager.removeCollateralToken(_token);
        emit CollateralTokenRemoved(_token, msg.sender);
    }

    // ========== PAUSER_ROLE FUNCTIONS ==========
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ========== UPGRADER_ROLE FUNCTIONS ==========
    /**
     * @notice set collateral manager (only once)
     * @param _collateralManager the address of collateral manager
     * @dev CollateralManager intent to be assign only once, since it stores user balances
     */
    function setCollateralManager(address _collateralManager) external onlyRole(UPGRADER_ROLE) {
        require(address(s_collateralManager) == address(0), LendingCore__CollateralManagerAlreadySet());
        s_collateralManager = ICollateralManager(_collateralManager);
    }

    /**
     * @notice set price orcle
     * @param _priceOracle the address of price oracle
     */
    function setPriceOracle(address _priceOracle) external onlyRole(UPGRADER_ROLE) {
        s_priceOracle = IPriceOracle(_priceOracle);
    }

    /**
     * @notice set interest rate model
     * @param _interestRateModel the address of interest rate model
     */
    function setInterestRateModel(address _interestRateModel) external onlyRole(UPGRADER_ROLE) {
        s_interestRateModel = IInterestRateModel(_interestRateModel);
    }

    // ========== INTERNAL FUNCTIONS ==========
    /**
     * @notice get user token value in usd
     * @param _user address of user to get the balance from
     * @param _token address of token to check the value
     */
    function _getTotalTokenValueInUsd(address _user, address _token) internal returns (uint256) {
        uint256 assetAmount = s_collateralManager.getDepositedCollateral(_user, _token);
        return s_priceOracle.getValue(_token, assetAmount);
    }

    /**
     * @notice calculate total token that can be acquired with _amountUsd
     * @param _amountUsd the amount of usd to convert to token
     * @param _token the address of token to convert the _amountUsd to
     * @return amount the amount of token that can be acquired with _amountUsd
     * @dev this function suppose to be a view function, it's not because the oracle require updating state, also this tied to borrow token
     */
    function _usdToTokenAmount(uint256 _amountUsd, address _token) internal returns (uint256 amount) {
        uint256 tokenDecimals = 10 ** IERC20Metadata(_token).decimals();
        uint256 debtTokenPrice = s_priceOracle.getValue(_token, tokenDecimals);

        amount = Math.mulDiv(_amountUsd, tokenDecimals, debtTokenPrice);
    }

    function _getHealthFactor(address _user, address _token) internal returns (uint256) {
        Loan memory loan = s_userLoans[_user][_token];
        uint256 debtValue = loan.principal + loan.interestAccrued - loan.repaidAmount;
        if (debtValue == 0) return type(uint256).max;

        uint256 collateralValueInUsd = _getTotalTokenValueInUsd(_user, _token);
        uint256 collateralValueInDebtToken = _usdToTokenAmount(collateralValueInUsd, loan.borrowToken);

        // Apply LTV to collateral first
        uint256 riskAdjustedCollateral = Math.mulDiv(collateralValueInDebtToken, s_ltvBPS[_token], BPS_DENOMINATOR);

        // Then calculate health factor
        return Math.mulDiv(riskAdjustedCollateral, BPS_DENOMINATOR, debtValue);
    }

    // ========== VIEW FUNCTIONS ==========
    function getBorrowTokens() external view returns (address[] memory) {
        return s_borrowTokens;
    }

    function getAvailableSupply(address _token) external view returns (uint256) {
        return IERC20Metadata(_token).balanceOf(address(this));
    }

    function getTotalSupply(address _token) external view returns (uint256) {
        return s_totalDebt[_token] + IERC20Metadata(_token).balanceOf(address(this));
    }

    function getUtilizationBPS(address _token) public view returns (uint256) {
        uint256 totalBorrow = s_totalDebt[_token];
        uint256 totalSupply = totalBorrow + IERC20Metadata(_token).balanceOf(address(this));

        if (totalSupply == 0) return 0;

        return Math.mulDiv(totalBorrow, BPS_DENOMINATOR, totalSupply);
    }

    function getUserLoan(address _user, address _token) external view returns (Loan memory) {
        return s_userLoans[_user][_token];
    }

    function getCurrentInterestRateBPS(address _token, uint256 _duration)
        external
        view
        returns (uint256 interestRateBPS)
    {
        return s_interestRateModel.getBorrowRateBPS(_duration, getUtilizationBPS(_token));
    }

    function getMaxBorrowBeforeInterest(address _user, address _borrowToken, address _collateralToken)
        public
        returns (uint256 maxBorrow)
    {
        uint256 tokenValueInUsd = _getTotalTokenValueInUsd(_user, _collateralToken);
        uint256 tokenValueInBorrowToken = _usdToTokenAmount(tokenValueInUsd, _borrowToken);

        maxBorrow = Math.mulDiv(tokenValueInBorrowToken, s_ltvBPS[_collateralToken], BPS_DENOMINATOR);
    }
}
