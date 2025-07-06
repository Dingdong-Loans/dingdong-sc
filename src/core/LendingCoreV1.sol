// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.27;

import {AccessControlUpgradeable} from "@openzeppelin-upgradeable/contracts/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/contracts/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {CollateralManager} from "./CollateralManager.sol";
import {InterestRateModel} from "./InterestRateModel.sol";
import {PriceOracle} from "./PriceOracle.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract LendingCore is Initializable, PausableUpgradeable, AccessControlUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20Metadata;

    // ========== EVENTS ==========
    event DebtTokenAdded(address indexed manager, address indexed token);
    event DebtTokenRemoved(address indexed manager, address indexed token);
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
    error LendingCore__OverflowOrUnderflow();
    error LendingCore__ZeroAmount();
    error LendingCore__AmountExceedsLimit();
    error LendingCore__DivisionByZero();
    error LendingCore__InsufficientSupply();
    error LendingCore__ActiveLoan();
    error LendingCore__InactiveLoan();

    // ========== TYPE DECLARATIONS ==========
    struct Loan {
        address borrowToken;
        uint256 borrowAmount;
        uint256 repaidAmount;
        uint64 startTime;
        uint64 dueDate;
        bool active;
    }
    // perhaps add amount liquidated etc

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
    CollateralManager public s_collateralManager;
    InterestRateModel public s_interestRateModel;
    PriceOracle public s_priceOracle;

    // ========== STORAGES ==========
    // Loan parameter
    mapping(address => uint16) public s_ltv;
    mapping(address => uint16) public s_liquidationPenaltyBPS;
    uint64 public s_maxBorrowDuration = 730 days; // 2 years
    uint64 public s_gracePeriod = 1 hours;

    // Loan information
    address[] public s_debtTokens;
    address[] public s_collateralTokens;
    mapping(address => uint8) s_debtTokenDecimals;
    mapping(address => bool) s_isDebtTokenSupported;
    mapping(address => bool) s_isCollateralTokenSupported;
    mapping(address => uint256) public s_totalBorrow;
    mapping(address => mapping(address => Loan)) public s_userLoans;
    mapping(address => uint256) s_liquidatedFunds;

    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address defaultAdmin, address pauser, address upgrader) public initializer {
        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(UPGRADER_ROLE, upgrader);
    }

    // ========== MAIN FUNCTIONS ==========
    /**
     * @notice deposit collateral to protocol
     * @param _token address of token to deposit
     * @param _amount amount to deposit
     */
    function depositCollateral(address _token, uint256 _amount) external {
        IERC20Metadata(_token).safeTransferFrom(msg.sender, address(this), _amount);
        s_collateralManager.deposit(msg.sender, _token, _amount);

        emit CollateralDeposited(msg.sender, _token, _amount);
    }

    /**
     * @notice withdraw collateral to protocol
     * @param _token address of token to withdraw
     * @param _amount amount to withdraw
     */
    function withdrawCollateral(address _token, uint256 _amount) external {
        IERC20Metadata(_token).safeTransfer(msg.sender, _amount);
        s_collateralManager.withdraw(msg.sender, _token, _amount);

        emit CollateralDeposited(msg.sender, _token, _amount);
    }

    /**
     * @notice borrow token of choice
     * @param _borrowToken the address of token to borrow
     * @param _amount the amount to borrow
     * @param _collateralToken the address of collateral token
     * @param _duration the borrow duration
     */
    function borrow(address _borrowToken, uint256 _amount, address _collateralToken, uint64 _duration) external {
        uint256 interestRateBPS = s_interestRateModel.getBorrowRateBPS(_borrowToken, _duration);

        uint256 collateralValueInUsd = s_collateralManager.getTotalTokenValueInUsd(msg.sender, _collateralToken);
        uint256 collateralValueInDebtToken = _usdToTokenAmount(_borrowToken, collateralValueInUsd);

        uint256 maxBorrowBeforeInterest = Math.mulDiv(collateralValueInDebtToken, s_ltv[_borrowToken], BPS_DENOMINATOR);
        uint256 maxBorrowAfterInterest =
            Math.mulDiv(maxBorrowBeforeInterest, BPS_DENOMINATOR, BPS_DENOMINATOR + interestRateBPS);

        if (_amount > maxBorrowAfterInterest) revert LendingCore__AmountExceedsLimit();

        Loan storage userLoan = s_userLoans[msg.sender][_collateralToken];
        userLoan.borrowToken = _borrowToken;
        userLoan.borrowAmount = Math.mulDiv(_amount, BPS_DENOMINATOR + interestRateBPS, BPS_DENOMINATOR);
        userLoan.startTime = uint64(block.timestamp);
        /// @dev no check for time exploit yet
        userLoan.dueDate = uint64(block.timestamp + _duration);
        userLoan.active = true;
        s_totalBorrow[_borrowToken] += _amount;

        IERC20Metadata(_borrowToken).safeTransfer(msg.sender, _amount);

        emit Borrowed(msg.sender, _borrowToken, _amount, _collateralToken);
    }

    /**
     * @notice repay borrowed token
     * @param _collateralToken address of collateral token used as collateral on a loan
     * @param _amount amount to be repayed
     */
    function repay(address _collateralToken, uint256 _amount) external {
        /// @dev do not put checks for isCollateralToken supported in case the token is remove but some users still have debt
        // if (_collateralToken == address(0)) revert Dingdong__InvalidAddress();

        Loan storage userLoan = s_userLoans[msg.sender][_collateralToken];
        uint256 borrowAmount = userLoan.borrowAmount;
        uint256 repaidAmount = userLoan.repaidAmount;
        // if (!userLoan.active) revert Dingdong__InactiveLoan();
        // if (_amount > debtAmount) revert Dingdong__AmountExceedsLimit();

        userLoan.repaidAmount += _amount;
        s_totalBorrow[_collateralToken] -= _amount;
        if (borrowAmount == (repaidAmount + _amount)) {
            delete s_userLoans[msg.sender][_collateralToken];
        }

        IERC20Metadata(userLoan.borrowToken).safeTransferFrom(msg.sender, address(this), _amount);

        emit Repaid(msg.sender, _collateralToken, _amount);
    }

    // ========== LIQUIDATOR_ROLE FUNCTIONS ==========
    /**
     * @notice liquidate undercollateralized user
     * @param _user the address of user to liquidate
     * @param _collateralToken the address of collateral token to liquidate
     */
    function liquidate(address _user, address _collateralToken) external onlyRole(LIQUIDATOR_ROLE) {
        Loan memory userLoan = s_userLoans[_user][_collateralToken];
        address borrowToken = userLoan.borrowToken;
        uint256 userDebtUsd = s_priceOracle.getValue(borrowToken, userLoan.borrowAmount - userLoan.repaidAmount);

        require(_getHealthFactor(_user, _collateralToken) < BPS_DENOMINATOR, "Health factor is already >= 1");

        uint256 denominator = Math.mulDiv(
            s_ltv[_collateralToken], (BPS_DENOMINATOR + s_liquidationPenaltyBPS[_collateralToken]), BPS_DENOMINATOR
        );
        uint256 repayAmountUsd = Math.mulDiv(userDebtUsd, BPS_DENOMINATOR, denominator);

        if (repayAmountUsd > userDebtUsd) {
            repayAmountUsd = userDebtUsd;
        }

        uint256 repayTokenAmount = _usdToTokenAmount(borrowToken, repayAmountUsd);
        uint256 penaltyUsd = Math.mulDiv(repayAmountUsd, s_liquidationPenaltyBPS[_collateralToken], BPS_DENOMINATOR);
        uint256 totalSeizeUsd = repayAmountUsd + penaltyUsd;
        uint256 seizeAmount = _usdToTokenAmount(_collateralToken, totalSeizeUsd);

        s_totalBorrow[borrowToken] -= repayTokenAmount;
        s_userLoans[_user][_collateralToken].repaidAmount += repayTokenAmount;
        /// @dev check to reset loan

        // 8. Seize collateral
        s_collateralManager.withdraw(_user, _collateralToken, seizeAmount);
        s_liquidatedFunds[_collateralToken] += seizeAmount;

        emit Liquidated(_user, _collateralToken, seizeAmount);
    }

    // ========== LIQUIDITY_MANAGER_ROLE FUNCTIONS ==========
    /**
     * @notice Add liquidity of specific token
     * @param _token address of debt token
     * @param _amount amount of liquidity to add
     */
    function addLiquidity(address _token, uint256 _amount) external onlyRole(LIQUIDITY_PROVIDER_ROLE) {
        IERC20Metadata(_token).safeTransferFrom(msg.sender, address(this), _amount);
        emit SupplyAdded(_token, msg.sender, _amount);
    }

    /**
     * @notice remove liquidity of specific token
     * @param _token address of debt token
     * @param _amount amount of liquidity to remove
     */
    function removeLiquidity(address _token, uint256 _amount) external onlyRole(LIQUIDITY_PROVIDER_ROLE) {
        IERC20Metadata(_token).safeTransfer(msg.sender, _amount);
        emit SupplyRemoved(_token, msg.sender, _amount);
    }

    function withdrawLiquidatedCollateral(address _collateralToken, uint256 _amount)
        external
        onlyRole(LIQUIDITY_PROVIDER_ROLE)
    {
        IERC20Metadata(_collateralToken).safeTransfer(msg.sender, _amount);
    }

    // ========== TOKEN_MANAGER_ROLE FUNCTIONS ==========
    /**
     * @notice list new debt token
     * @param _token address of debt token to add
     * @param _priceFeed address of debt token pricefeed
     */
    function addDebtToken(address _token, address _priceFeed) external onlyRole(TOKEN_MANAGER_ROLE) {
        s_priceOracle.setPriceFeed(_token, _priceFeed); // use try
        s_debtTokens.push(_token);
        s_debtTokenDecimals[_token] = IERC20Metadata(_token).decimals();
        s_isDebtTokenSupported[_token] = true;

        emit DebtTokenAdded(_token, msg.sender);
    }

    /**
     * @notice remove debt token from list
     * @param _token address of debt token to remove
     * @dev currently does not remove associated oracle
     */
    function removeDebtToken(address _token) external onlyRole(TOKEN_MANAGER_ROLE) {
        uint256 length = s_debtTokens.length;
        for (uint256 i = 0; i < length;) {
            if (s_debtTokens[i] == _token) {
                s_debtTokens[i] = s_debtTokens[length - 1];
                s_debtTokens.pop();

                unchecked {
                    i++;
                }

                break;
            }
        }

        s_isDebtTokenSupported[_token] = false;
        emit DebtTokenRemoved(_token, msg.sender);
    }

    function addCollateralToken(address _token, address _priceFeed) external onlyRole(TOKEN_MANAGER_ROLE) {}

    function removeCollateralToken() external onlyRole(TOKEN_MANAGER_ROLE) {}

    // ========== PAUSER_ROLE FUNCTIONS ==========
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ========== UPGRADER_ROLE FUNCTIONS ==========
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // ========== INTERNAL FUNCTIONS ==========
    /**
     * @notice calculate total token that can be acquired with _amountUsd
     * @param _token the address of token to convert the _amountUsd to
     * @param _amountUsd the amount of usd to convert to token
     * @return amount the amount of token that can be acquired with _amountUsd
     * @dev this function suppose to be a view function, it's not because the oracle require updating state
     */
    function _usdToTokenAmount(address _token, uint256 _amountUsd) internal returns (uint256 amount) {
        uint256 tokenDecimals = 10 ** s_debtTokenDecimals[_token];
        uint256 debtTokenPrice = s_priceOracle.getValue(_token, tokenDecimals);

        amount = Math.mulDiv(_amountUsd, tokenDecimals, debtTokenPrice);
    }

    /**
     * @notice normalize a value to desired decimals
     * @param _value the value to be normalized
     * @param _fromDecimal the decimal of _value
     * @param _toDecimal the desired decimal of _value
     * @return normalizedValue the normalized value in desired decimals
     */
    function _getNormalizedDecimals(uint256 _value, uint8 _fromDecimal, uint8 _toDecimal)
        internal
        pure
        returns (uint256 normalizedValue)
    {
        require(_fromDecimal <= 77 && _toDecimal <= 77, LendingCore__OverflowOrUnderflow());

        if (_fromDecimal == _toDecimal) {
            normalizedValue = _value;
        }

        uint8 decimalDiff = _fromDecimal > _toDecimal ? _fromDecimal - _toDecimal : _toDecimal - _fromDecimal;

        uint256 scale = 10 ** decimalDiff;

        if (_toDecimal > _fromDecimal) {
            normalizedValue = Math.mulDiv(_value, scale, 1);
        } else {
            normalizedValue = Math.mulDiv(_value, 1, scale);
        }
    }

    function _getHealthFactor(address _user, address _token) internal returns (uint256) {
        uint256 collateralValue = s_collateralManager.getTotalTokenValueInUsd(_user, _token);
        Loan memory loan = s_userLoans[_user][_token];
        uint256 debtValue = loan.borrowAmount - loan.repaidAmount;

        if (debtValue == 0) return type(uint256).max;

        // Apply LTV to collateral first
        uint256 riskAdjustedCollateral = Math.mulDiv(collateralValue, s_ltv[_token], BPS_DENOMINATOR);

        // Then calculate health factor
        return Math.mulDiv(riskAdjustedCollateral, BPS_DENOMINATOR, debtValue);
    }

    // ========== VIEW FUNCTIONS ==========
    function getAvailableSupply(address _token) external view returns (uint256) {
        return IERC20Metadata(_token).balanceOf(address(this));
    }

    function getTotalSupply(address _token) external view returns (uint256) {
        return s_totalBorrow[_token] + IERC20Metadata(_token).balanceOf(address(this));
    }

    function getUtilizationBPS(address _token) external view returns (uint256) {
        uint256 totalBorrow = s_totalBorrow[_token];
        uint256 totalSupply = totalBorrow + IERC20Metadata(_token).balanceOf(address(this));

        if (totalSupply == 0) return 0;

        return Math.mulDiv(totalBorrow, BPS_DENOMINATOR, totalSupply);
    }
}
