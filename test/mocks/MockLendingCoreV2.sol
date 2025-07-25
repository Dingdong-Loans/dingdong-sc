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
    error LendingCore__ParamZeroNotAllowed();
    error LendingCore__AmountExceedsLimit(uint256 max, uint256 attempted);
    error LendingCore__DurationExceedsLimit(uint256 max, uint256 attemted);
    error LendingCore__InsufficientBalance(address token, uint256 available);
    error LendingCore__LoanParamViolated();
    error LendingCore__LoanIsActive();
    error LendingCore__LoanIsInactive();
    error LendingCore__UnsupportedToken(address token);
    error LendingCore__TokenAlreadySupported(address token);
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
    uint40 public s_minBorrowDuration;
    uint40 public s_maxBorrowDuration;
    uint40 public s_gracePeriod;
    mapping(address => uint16) public s_ltvBPS;
    mapping(address => uint16) public s_liquidationPenaltyBPS;
    mapping(address => uint256) public s_minBorrowAmount;
    mapping(address => uint256) public s_maxBorrowAmount;

    // Protocol information
    address[] public s_borrowTokens;
    mapping(address => bool) public s_isBorrowTokenSupported;
    mapping(address => uint256) public s_totalDebt;
    mapping(address => mapping(address => Loan)) public s_userLoans;
    mapping(address => uint256) public s_liquidatedCollateral;

    // KYC restriction(unimplemented)
    // mapping(address => bool) public s_isKYCed;
    uint256 num;

    uint256[50] private __gap;

    function setNum(uint256 _num) external {
        num = _num;
    }

    function getNum() external view returns (uint256) {
        return num;
    }

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
    /**
     * @notice deposit collateral to protocol
     * @param _collatearlToken address of token to deposit
     * @param _amount amount to deposit
     */
    function depositCollateral(address _collatearlToken, uint256 _amount) external nonReentrant whenNotPaused {
        ICollateralManager collateralManager = s_collateralManager;

        require(_collatearlToken != address(0), LendingCore__InvalidAddress());
        require(_amount != 0, LendingCore__ParamZeroNotAllowed());
        require(
            collateralManager.s_isCollateralTokenSupported(_collatearlToken),
            LendingCore__UnsupportedToken(_collatearlToken)
        );

        IERC20Metadata(_collatearlToken).safeTransferFrom(msg.sender, address(this), _amount);
        collateralManager.deposit(msg.sender, _collatearlToken, _amount);

        emit CollateralDeposited(msg.sender, _collatearlToken, _amount);
    }

    /**
     * @notice withdraw collateral to protocol
     * @param _collateralToken address of token to withdraw
     * @param _amount amount to withdraw
     */
    function withdrawCollateral(address _collateralToken, uint256 _amount) external nonReentrant whenNotPaused {
        ICollateralManager collateralManager = s_collateralManager;
        uint256 depositedCollateral = collateralManager.getDepositedCollateral(msg.sender, _collateralToken);

        require(_collateralToken != address(0), LendingCore__InvalidAddress());
        require(_amount != 0, LendingCore__ParamZeroNotAllowed());
        require(
            collateralManager.s_isCollateralTokenSupported(_collateralToken),
            LendingCore__UnsupportedToken(_collateralToken)
        );
        require(depositedCollateral >= _amount, LendingCore__AmountExceedsLimit(depositedCollateral, _amount));

        collateralManager.withdraw(msg.sender, _collateralToken, _amount);
        require(_getHealthFactor(msg.sender, _collateralToken) >= BPS_DENOMINATOR, LendingCore__LoanIsActive());

        IERC20Metadata(_collateralToken).safeTransfer(msg.sender, _amount);

        emit CollateralWithdrawn(msg.sender, _collateralToken, _amount);
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
        require(
            _amount >= s_minBorrowAmount[_borrowToken] && _amount <= s_maxBorrowAmount[_borrowToken],
            LendingCore__LoanParamViolated()
        );
        require(_duration >= s_minBorrowDuration && _duration <= s_maxBorrowDuration, LendingCore__LoanParamViolated());
        require(
            s_collateralManager.s_isCollateralTokenSupported(_collateralToken),
            LendingCore__UnsupportedToken(_collateralToken)
        );
        require(s_isBorrowTokenSupported[_borrowToken], LendingCore__UnsupportedToken(_borrowToken));

        uint256 maxBorrowDuration = s_maxBorrowDuration;
        uint256 availableLiquidity = IERC20Metadata(_borrowToken).balanceOf(address(this));

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
        require(_amount != 0, LendingCore__ParamZeroNotAllowed());
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
        Loan storage userLoan = s_userLoans[_user][_collateralToken];
        ICollateralManager collateralManager = s_collateralManager;

        require(_user != address(0) && _collateralToken != address(0), LendingCore__InvalidAddress());
        require(
            collateralManager.s_isCollateralTokenSupported(_collateralToken),
            LendingCore__UnsupportedToken(_collateralToken)
        );

        require(
            _getHealthFactor(_user, _collateralToken) < BPS_DENOMINATOR
                || userLoan.dueDate + s_gracePeriod < block.timestamp,
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

        require(repayTokenAmount != 0, LendingCore__ParamZeroNotAllowed());
        if (repayTokenAmount > remainingDebt) repayTokenAmount = remainingDebt;

        require(s_totalDebt[borrowToken] >= repayTokenAmount, LendingCore__MathOverflow());

        uint256 seizeAmount;
        {
            uint256 penaltyUsd = Math.mulDiv(repayAmountUsd, s_liquidationPenaltyBPS[_collateralToken], BPS_DENOMINATOR);
            uint256 totalSeizeUsd = repayAmountUsd + penaltyUsd;

            seizeAmount = _usdToTokenAmount(totalSeizeUsd, _collateralToken);
            uint256 collateralBalance = collateralManager.getDepositedCollateral(_user, _collateralToken);

            if (seizeAmount > collateralBalance) {
                seizeAmount = collateralBalance;
                totalSeizeUsd = s_priceOracle.getValue(_collateralToken, seizeAmount);
                repayAmountUsd = totalSeizeUsd - penaltyUsd;
                repayTokenAmount = _usdToTokenAmount(repayAmountUsd, borrowToken);
            }
        }

        if (userLoan.repaidAmount >= totalDebt) {
            delete s_userLoans[_user][_collateralToken];
        }

        s_totalDebt[borrowToken] -= repayTokenAmount;
        userLoan.repaidAmount += repayTokenAmount;
        userLoan.totalLiquidated += seizeAmount;
        s_liquidatedCollateral[_collateralToken] += seizeAmount;
        collateralManager.withdraw(_user, _collateralToken, seizeAmount);

        emit Liquidated(_user, _collateralToken, seizeAmount);
    }

    // ========== LIQUIDITY_PROVIDER_ROLE FUNCTIONS ==========
    /**
     * @notice Add liquidity of specific token
     * @param _borrowToken address of borrow token
     * @param _amount amount of liquidity to add
     */
    function addLiquidity(address _borrowToken, uint256 _amount)
        external
        onlyRole(LIQUIDITY_PROVIDER_ROLE)
        nonReentrant
    {
        require(s_isBorrowTokenSupported[_borrowToken], LendingCore__UnsupportedToken(_borrowToken));
        require(_borrowToken != address(0), LendingCore__InvalidAddress());
        require(_amount != 0, LendingCore__ParamZeroNotAllowed());

        IERC20Metadata(_borrowToken).safeTransferFrom(msg.sender, address(this), _amount);
        emit SupplyAdded(_borrowToken, msg.sender, _amount);
    }

    /**
     * @notice remove liquidity of specific token
     * @param _borrowToken address of borrow token
     * @param _amount amount of liquidity to remove
     */
    function removeLiquidity(address _borrowToken, uint256 _amount)
        external
        onlyRole(LIQUIDITY_PROVIDER_ROLE)
        nonReentrant
    {
        uint256 availableLiquidity = IERC20Metadata(_borrowToken).balanceOf(address(this));

        require(s_isBorrowTokenSupported[_borrowToken], LendingCore__UnsupportedToken(_borrowToken));
        require(_borrowToken != address(0), LendingCore__InvalidAddress());
        require(_amount != 0, LendingCore__ParamZeroNotAllowed());
        require(availableLiquidity >= _amount, LendingCore__InsufficientBalance(_borrowToken, availableLiquidity));

        IERC20Metadata(_borrowToken).safeTransfer(msg.sender, _amount);
        emit SupplyRemoved(_borrowToken, msg.sender, _amount);
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
        require(_amount != 0, LendingCore__ParamZeroNotAllowed());
        require(availableAmount >= _amount, LendingCore__InsufficientBalance(_collateralToken, availableAmount));

        IERC20Metadata(_collateralToken).safeTransfer(msg.sender, _amount);
    }

    // ========== PARAMETER_MANAGER_ROLE FUNCTIONS ==========
    /**
     * @notice set collateral token LTV
     * @param _collateralToken the address of collateral token
     * @param _ltvBps the LTV Ratio in Basis Points
     */
    function setLTV(address _collateralToken, uint16 _ltvBps) external onlyRole(PARAMETER_MANAGER_ROLE) {
        require(_collateralToken != address(0), LendingCore__InvalidAddress());
        require(_ltvBps != 0, LendingCore__ParamZeroNotAllowed());
        require(_ltvBps <= BPS_DENOMINATOR, LendingCore__AmountExceedsLimit(BPS_DENOMINATOR, _ltvBps));

        if (_ltvBps != s_ltvBPS[_collateralToken]) {
            s_ltvBPS[_collateralToken] = _ltvBps;
        }
    }

    /**
     * @notice set collateral token liquidation penalty
     * @param _collateralToken the address of collateral token
     * @param _penaltyBps the penalty amount in Basis Points
     */
    function setLiquidationPenalty(address _collateralToken, uint16 _penaltyBps)
        external
        onlyRole(PARAMETER_MANAGER_ROLE)
    {
        require(_collateralToken != address(0), LendingCore__InvalidAddress());
        require(_penaltyBps != 0, LendingCore__ParamZeroNotAllowed());
        require(_penaltyBps <= BPS_DENOMINATOR, LendingCore__AmountExceedsLimit(BPS_DENOMINATOR, _penaltyBps));

        if (s_liquidationPenaltyBPS[_collateralToken] != _penaltyBps) {
            s_liquidationPenaltyBPS[_collateralToken] = _penaltyBps;
        }
    }

    /**
     * @notice set minimum borrow amount
     * @param _borrowToken the address of borrow token
     * @param _minAmount the minimum amount to borrow
     */
    function setMinBorrowAmount(address _borrowToken, uint256 _minAmount) external onlyRole(PARAMETER_MANAGER_ROLE) {
        require(_borrowToken != address(0), LendingCore__InvalidAddress());
        require(s_isBorrowTokenSupported[_borrowToken], LendingCore__UnsupportedToken(_borrowToken));
        require(_minAmount != 0, LendingCore__ParamZeroNotAllowed());
        require(
            _minAmount <= s_maxBorrowAmount[_borrowToken],
            LendingCore__AmountExceedsLimit(s_maxBorrowAmount[_borrowToken], _minAmount)
        );

        if (s_minBorrowAmount[_borrowToken] != _minAmount) {
            s_minBorrowAmount[_borrowToken] = _minAmount;
        }
    }

    /**
     * @notice set maximum borrow amount
     * @param _borrowToken the address of borrow token
     * @param _maxAmount the maximum amount to borrow
     */
    function setMaxBorrowAmount(address _borrowToken, uint256 _maxAmount) external onlyRole(PARAMETER_MANAGER_ROLE) {
        require(_borrowToken != address(0), LendingCore__InvalidAddress());
        require(s_isBorrowTokenSupported[_borrowToken], LendingCore__UnsupportedToken(_borrowToken));
        require(_maxAmount != 0, LendingCore__ParamZeroNotAllowed());
        require(
            _maxAmount >= s_minBorrowAmount[_borrowToken],
            LendingCore__AmountExceedsLimit(s_minBorrowAmount[_borrowToken], _maxAmount)
        );

        if (s_maxBorrowAmount[_borrowToken] != _maxAmount) {
            s_maxBorrowAmount[_borrowToken] = _maxAmount;
        }
    }

    /**
     * @notice set minimum borrow duration
     * @param _duration the duration in seconds
     */
    function setMinBorrowDuration(uint40 _duration) external onlyRole(PARAMETER_MANAGER_ROLE) {
        require(_duration != 0, LendingCore__ParamZeroNotAllowed());
        require(_duration <= s_maxBorrowDuration, LendingCore__DurationExceedsLimit(s_maxBorrowDuration, _duration));

        if (s_minBorrowDuration != _duration) {
            s_minBorrowDuration = _duration;
        }
    }

    /**
     * @notice set maximum borrow duration
     * @param _duration the duration in seconds
     */
    function setMaxBorrowDuration(uint40 _duration) external onlyRole(PARAMETER_MANAGER_ROLE) {
        require(_duration != 0, LendingCore__ParamZeroNotAllowed());
        require(_duration >= s_minBorrowDuration, LendingCore__DurationExceedsLimit(s_minBorrowDuration, _duration));

        if (s_maxBorrowDuration != _duration) {
            s_maxBorrowDuration = _duration;
        }
    }

    /**
     * @notice set grace period
     * @param _period the period duration in seconds
     */
    function setGracePeriod(uint40 _period) external onlyRole(PARAMETER_MANAGER_ROLE) {
        require(_period != 0, LendingCore__ParamZeroNotAllowed());

        if (s_gracePeriod != _period) {
            s_gracePeriod = _period;
        }
    }

    // ========== TOKEN_MANAGER_ROLE FUNCTIONS ==========
    /**
     * @notice list new borrow token
     * @param _borrowToken address of borrow token to add
     * @param base the base currency of the borrow token
     * @param quote the quote currency of the borrow token
     */
    function addBorrowToken(address _borrowToken, string memory base, string memory quote)
        external
        onlyRole(TOKEN_MANAGER_ROLE)
        nonReentrant
    {
        require(_borrowToken != address(0), LendingCore__InvalidAddress());
        require(bytes(base).length != 0 && bytes(quote).length != 0, LendingCore__ParamZeroNotAllowed());
        require(!s_isBorrowTokenSupported[_borrowToken], LendingCore__TokenAlreadySupported(_borrowToken));

        s_priceOracle.setPriceFeed(_borrowToken, base, quote);
        s_borrowTokens.push(_borrowToken);
        s_isBorrowTokenSupported[_borrowToken] = true;

        emit BorrowTokenAdded(_borrowToken, msg.sender);
    }

    /**
     * @notice remove borrow token from list
     * @param _borrowToken address of borrow token to remove
     * @dev currently does not remove associated oracle
     */
    function removeBorrowToken(address _borrowToken) external onlyRole(TOKEN_MANAGER_ROLE) nonReentrant {
        require(_borrowToken != address(0), LendingCore__InvalidAddress());
        require(s_isBorrowTokenSupported[_borrowToken], LendingCore__UnsupportedToken(_borrowToken));

        uint256 length = s_borrowTokens.length;
        for (uint256 i = 0; i < length;) {
            if (s_borrowTokens[i] == _borrowToken) {
                s_borrowTokens[i] = s_borrowTokens[length - 1];
                s_borrowTokens.pop();

                unchecked {
                    i++;
                }

                break;
            }
        }

        delete s_isBorrowTokenSupported[_borrowToken];
        // delete s_totalDebt[_borrowToken];

        emit BorrowTokenRemoved(_borrowToken, msg.sender);
    }

    /**
     * @notice list new collateral token
     * @param _collateralToken address of collateral token to add
     * @param base the base currency of the borrow token
     * @param quote the quote currency of the borrow token
     */
    function addCollateralToken(address _collateralToken, string memory base, string memory quote)
        external
        onlyRole(TOKEN_MANAGER_ROLE)
        nonReentrant
    {
        require(_collateralToken != address(0), LendingCore__InvalidAddress());
        require(bytes(base).length != 0 && bytes(quote).length != 0, LendingCore__ParamZeroNotAllowed());
        require(
            !s_collateralManager.s_isCollateralTokenSupported(_collateralToken),
            LendingCore__TokenAlreadySupported(_collateralToken)
        );

        s_collateralManager.addCollateralToken(_collateralToken);
        s_priceOracle.setPriceFeed(_collateralToken, base, quote);

        emit CollateralTokenAdded(msg.sender, _collateralToken);
    }

    /**
     * @notice remove collateral token from list
     * @param _collateralToken address of collateral token to remove
     * @dev currently does not remove associated oracle
     */
    function removeCollateralToken(address _collateralToken) external onlyRole(TOKEN_MANAGER_ROLE) nonReentrant {
        require(_collateralToken != address(0), LendingCore__InvalidAddress());
        require(
            s_collateralManager.s_isCollateralTokenSupported(_collateralToken),
            LendingCore__UnsupportedToken(_collateralToken)
        );

        s_collateralManager.removeCollateralToken(_collateralToken);
        emit CollateralTokenRemoved(_collateralToken, msg.sender);
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
        require(_collateralManager != address(0), LendingCore__InvalidAddress());

        s_collateralManager = ICollateralManager(_collateralManager);
    }

    /**
     * @notice set price orcle
     * @param _priceOracle the address of price oracle
     */
    function setPriceOracle(address _priceOracle) external onlyRole(UPGRADER_ROLE) {
        require(_priceOracle != address(0), LendingCore__InvalidAddress());
        s_priceOracle = IPriceOracle(_priceOracle);
    }

    /**
     * @notice set interest rate model
     * @param _interestRateModel the address of interest rate model
     */
    function setInterestRateModel(address _interestRateModel) external onlyRole(UPGRADER_ROLE) {
        require(_interestRateModel != address(0), LendingCore__InvalidAddress());
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
        Loan storage loan = s_userLoans[_user][_token];
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

    function getAvailableSupply(address _borrowToken) external view returns (uint256) {
        return IERC20Metadata(_borrowToken).balanceOf(address(this));
    }

    function getTotalSupply(address _borrowToken) external view returns (uint256) {
        return s_totalDebt[_borrowToken] + IERC20Metadata(_borrowToken).balanceOf(address(this));
    }

    function getUtilizationBPS(address _borrowToken) public view returns (uint256) {
        uint256 totalBorrow = s_totalDebt[_borrowToken];
        uint256 totalSupply = totalBorrow + IERC20Metadata(_borrowToken).balanceOf(address(this));

        if (totalSupply == 0) return 0;

        return Math.mulDiv(totalBorrow, BPS_DENOMINATOR, totalSupply);
    }

    function getUserLoan(address _user, address _collateralToken) external view returns (Loan memory) {
        return s_userLoans[_user][_collateralToken];
    }

    function getCurrentInterestRateBPS(address _borrowToken, uint256 _duration)
        external
        view
        returns (uint256 interestRateBPS)
    {
        return s_interestRateModel.getBorrowRateBPS(_duration, getUtilizationBPS(_borrowToken));
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
