// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {LendingCoreV1} from "../../src/core/LendingCoreV1.sol";
import {CollateralManager} from "../../src/core/CollateralManager.sol";
import {InterestRateModel} from "../../src/core/InterestRateModel.sol";
import {PriceOracle} from "../../src/core/PriceOracle.sol";
import {TellorUser} from "../../src/tellor/TellorUser.sol";
import {TellorPlayground} from "@tellor/contracts/TellorPlayground.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockLendingCoreV2} from "../mocks/MockLendingCoreV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract LendingCoreV1Test is Test {
    // Constants
    string private constant USD = "usd";
    string private constant USDT = "usdt";
    string private constant IDRX = "idrx";
    string private constant BTC = "btc";
    string private constant ETH = "eth";
    string private constant QUERY_TYPE = "SpotPrice";

    uint256 private constant DISPUTE_BUFFER = 20 minutes;
    uint256 private constant STALENESS_AGE = 2 hours;
    uint256 private constant BPS_DENOMINATOR = 10000;

    // Price constants (8 decimals)
    uint256 private constant PRICE_USDT = 1e8;
    uint256 private constant PRICE_IDRX = 6042;
    uint256 private constant PRICE_BTC = 100000e8;
    uint256 private constant PRICE_ETH = 2500e8;

    // Query data and IDs
    bytes private constant QUERY_DATA_USDT = abi.encode(QUERY_TYPE, abi.encode(USDT, USD));
    bytes private constant QUERY_DATA_IDRX = abi.encode(QUERY_TYPE, abi.encode(IDRX, USD));
    bytes private constant QUERY_DATA_BTC = abi.encode(QUERY_TYPE, abi.encode(BTC, USD));
    bytes private constant QUERY_DATA_ETH = abi.encode(QUERY_TYPE, abi.encode(ETH, USD));

    bytes32 private constant QUERY_ID_USDT = keccak256(QUERY_DATA_USDT);
    bytes32 private constant QUERY_ID_IDRX = keccak256(QUERY_DATA_IDRX);
    bytes32 private constant QUERY_ID_BTC = keccak256(QUERY_DATA_BTC);
    bytes32 private constant QUERY_ID_ETH = keccak256(QUERY_DATA_ETH);

    // Contracts
    ERC1967Proxy public lendingProxy;
    LendingCoreV1 public lending;
    LendingCoreV1 public castLendingProxy;

    ERC1967Proxy public collateralManagerProxy;
    CollateralManager public collateralManager;
    CollateralManager public castCollateralManagerProxy;

    InterestRateModel public interestRateModel;
    PriceOracle public priceOracle;

    MockERC20 public tokenUSDT;
    MockERC20 public tokenIDRX;
    MockERC20 public tokenBTC;
    MockERC20 public tokenETH;

    TellorPlayground public tellorOracle;
    TellorUser public pricefeedUSDT;
    TellorUser public pricefeedIDRX;
    TellorUser public pricefeedBTC;
    TellorUser public pricefeedETH;

    // Roles
    address public admin = makeAddr("ADMIN");
    address public pauser = makeAddr("PAUSER");
    address public upgrader = makeAddr("UPGRADER");
    address public parameterManager = makeAddr("PARAMETER_MANAGER");
    address public liquidityProvider = makeAddr("LIQUIDITY_PROVIDER");
    address public tokenManager = makeAddr("TOKEN_MANAGER");
    address public liquidator = makeAddr("LIQUIDATOR");
    address public tokenHandler = makeAddr("TOKEN_HANDLER");
    address public oracleHandler = makeAddr("ORACLE_HANDLER");
    address public user1 = makeAddr("USER1");

    // Events
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed user, address indexed token, uint256 amount);
    event Borrowed(address indexed user, address indexed borrowToken, uint256 amount, address indexed collateralToken);
    event Repaid(address indexed user, address indexed collateralToken, uint256 amount);
    event Liquidated(address indexed user, address indexed collateralToken, uint256 seizeAmount);

    function setUp() public {
        vm.startPrank(admin);

        // Initialize LendingCoreV1
        bytes memory initializeLendingData = abi.encodeWithSelector(
            LendingCoreV1.initialize.selector,
            admin,
            [pauser, upgrader, parameterManager, tokenManager, liquidityProvider, liquidator]
        );
        lending = new LendingCoreV1();
        lendingProxy = new ERC1967Proxy(address(lending), initializeLendingData);
        castLendingProxy = LendingCoreV1(address(lendingProxy));

        // Initialize CollateralManager
        bytes memory initializeCollateralManagerData =
            abi.encodeWithSelector(CollateralManager.initialize.selector, address(lendingProxy));
        collateralManager = new CollateralManager();
        collateralManagerProxy = new ERC1967Proxy(address(collateralManager), initializeCollateralManagerData);
        castCollateralManagerProxy = CollateralManager(address(collateralManagerProxy));

        // Initialize supporting contracts
        priceOracle = new PriceOracle(address(lendingProxy));
        interestRateModel = new InterestRateModel(address(lendingProxy));

        vm.stopPrank();

        // Configure LendingCoreV1
        vm.startPrank(upgrader);
        castLendingProxy.setCollateralManager(address(collateralManagerProxy));
        castLendingProxy.setInterestRateModel(address(interestRateModel));
        castLendingProxy.setPriceOracle(address(priceOracle));
        vm.stopPrank();
    }

    // ========== Helper Functions ==========
    function _setupTokens() internal {
        vm.startPrank(tokenHandler);
        tokenUSDT = new MockERC20("USDT", "USDT", 18);
        tokenBTC = new MockERC20("Bitcoin", "BTC", 18);
        tokenIDRX = new MockERC20("Indonesian Rupiahx", "IDRX", 8);
        tokenETH = new MockERC20("Ether", "ETH", 8);
        vm.stopPrank();
    }

    function _setupPriceFeeds() internal {
        vm.startPrank(oracleHandler);
        tellorOracle = new TellorPlayground();
        pricefeedUSDT = new TellorUser(payable(address(tellorOracle)), USDT, USD);
        pricefeedIDRX = new TellorUser(payable(address(tellorOracle)), IDRX, USD);
        pricefeedBTC = new TellorUser(payable(address(tellorOracle)), BTC, USD);
        pricefeedETH = new TellorUser(payable(address(tellorOracle)), ETH, USD);

        tellorOracle.submitValue(QUERY_ID_USDT, abi.encode(PRICE_USDT), 0, QUERY_DATA_USDT);
        tellorOracle.submitValue(QUERY_ID_IDRX, abi.encode(PRICE_IDRX), 0, QUERY_DATA_IDRX);
        tellorOracle.submitValue(QUERY_ID_BTC, abi.encode(PRICE_BTC), 0, QUERY_DATA_BTC);
        tellorOracle.submitValue(QUERY_ID_ETH, abi.encode(PRICE_ETH), 0, QUERY_DATA_ETH);

        // Ensure values pass dispute buffer
        vm.warp(block.timestamp + DISPUTE_BUFFER + 1);
        vm.stopPrank();
    }

    function _setupTokensAndPriceFeeds() internal {
        _setupTokens();
        _setupPriceFeeds();
    }

    function _fund(address _token, address _account, uint256 _value) internal {
        vm.startPrank(tokenHandler);
        MockERC20(_token).mint(_account, _value);
        vm.stopPrank();
    }

    function _approveAndDepositCollateral(address user, address token, uint256 amount) internal {
        vm.startPrank(user);
        IERC20Metadata(token).approve(address(lendingProxy), amount);
        castLendingProxy.depositCollateral(token, amount);
        vm.stopPrank();
    }

    function _addBorrowToken(address token, address priceFeed) internal {
        vm.startPrank(tokenManager);
        castLendingProxy.addBorrowToken(token, priceFeed);
        vm.stopPrank();
    }

    function _addCollateralToken(address token, address priceFeed) internal {
        vm.startPrank(tokenManager);
        castLendingProxy.addCollateralToken(token, priceFeed);
        vm.stopPrank();
    }

    function _setLTV(address token, uint16 ltvBps) internal {
        vm.startPrank(parameterManager);
        castLendingProxy.setLTV(token, ltvBps);
        vm.stopPrank();
    }

    function _setMinBorrowAmount(address token, uint256 amount) internal {
        vm.startPrank(parameterManager);
        castLendingProxy.setMinBorrowAmount(token, amount);
        vm.stopPrank();
    }

    function _setMaxBorrowAmount(address token, uint256 amount) internal {
        vm.startPrank(parameterManager);
        castLendingProxy.setMaxBorrowAmount(token, amount);
        vm.stopPrank();
    }

    function _setMinBorrowDuration(uint40 _duration) internal {
        vm.startPrank(parameterManager);
        castLendingProxy.setMinBorrowDuration(_duration);
        vm.stopPrank();
    }

    function _setMaxBorrowDuration(uint40 _duration) internal {
        vm.startPrank(parameterManager);
        castLendingProxy.setMaxBorrowDuration(_duration);
        vm.stopPrank();
    }

    function _setGracePeriod(uint40 _period) internal {
        vm.startPrank(parameterManager);
        castLendingProxy.setGracePeriod(_period);
        vm.stopPrank();
    }

    function _setLiquidationPenalty(address token, uint16 penaltyBps) internal {
        vm.startPrank(parameterManager);
        castLendingProxy.setLiquidationPenalty(token, penaltyBps);
        vm.stopPrank();
    }

    function _addLiquidity(address token, uint256 amount) internal {
        vm.startPrank(liquidityProvider);
        IERC20Metadata(token).approve(address(lendingProxy), amount);
        castLendingProxy.addLiquidity(token, amount);
        vm.stopPrank();
    }

    function _usdToTokenAmount(uint256 _amountUsd, address _token) internal returns (uint256 amount) {
        uint256 tokenDecimals = 10 ** IERC20Metadata(_token).decimals();
        uint256 debtTokenPrice = priceOracle.getValue(_token, tokenDecimals);
        amount = Math.mulDiv(_amountUsd, tokenDecimals, debtTokenPrice);
    }

    // ========== Initialization Tests ==========
    function test_Initialization() public view {
        // Check roles
        assertTrue(castLendingProxy.hasRole(castLendingProxy.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(castLendingProxy.hasRole(castLendingProxy.PAUSER_ROLE(), pauser));
        assertTrue(castLendingProxy.hasRole(castLendingProxy.UPGRADER_ROLE(), upgrader));
        assertTrue(castLendingProxy.hasRole(castLendingProxy.PARAMETER_MANAGER_ROLE(), parameterManager));
        assertTrue(castLendingProxy.hasRole(castLendingProxy.TOKEN_MANAGER_ROLE(), tokenManager));
        assertTrue(castLendingProxy.hasRole(castLendingProxy.LIQUIDITY_PROVIDER_ROLE(), liquidityProvider));
        assertTrue(castLendingProxy.hasRole(castLendingProxy.LIQUIDATOR_ROLE(), liquidator));

        // Check initial state
        assertFalse(castLendingProxy.paused());
        assertEq(castLendingProxy.BPS_DENOMINATOR(), BPS_DENOMINATOR);

        // Check modules
        assertEq(address(castLendingProxy.s_collateralManager()), address(collateralManagerProxy));
        assertEq(address(castLendingProxy.s_interestRateModel()), address(interestRateModel));
        assertEq(address(castLendingProxy.s_priceOracle()), address(priceOracle));
    }

    // ========== Deposit Collateral Tests ==========
    function test_DepositCollateral() public {
        uint256 userBalance = 1e18;
        uint256 depositAmount = userBalance / 2;

        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _fund(address(tokenBTC), user1, userBalance);

        vm.startPrank(user1);
        tokenBTC.approve(address(lendingProxy), depositAmount);

        vm.expectEmit(true, true, true, true);
        emit CollateralDeposited(user1, address(tokenBTC), depositAmount);

        castLendingProxy.depositCollateral(address(tokenBTC), depositAmount);
        vm.stopPrank();

        uint256 depositedAmount = castCollateralManagerProxy.getDepositedCollateral(user1, address(tokenBTC));
        assertEq(depositedAmount, depositAmount);
    }

    function test_RevertWhen_DepositCollateral_ZeroAddressToken() public {
        vm.startPrank(user1);
        vm.expectRevert(LendingCoreV1.LendingCore__InvalidAddress.selector);
        castLendingProxy.depositCollateral(address(0), 1e18);
        vm.stopPrank();
    }

    function test_RevertWhen_DepositCollateral_ZeroAmount() public {
        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));

        vm.startPrank(user1);
        vm.expectRevert(LendingCoreV1.LendingCore__ZeroAmountNotAllowed.selector);
        castLendingProxy.depositCollateral(address(tokenBTC), 0);
        vm.stopPrank();
    }

    function test_RevertWhen_DepositCollateral_UnsupportedToken() public {
        _setupTokensAndPriceFeeds();
        _fund(address(tokenETH), user1, 1e18);

        vm.startPrank(user1);
        tokenETH.approve(address(castLendingProxy), 1e18);
        vm.expectRevert(abi.encodeWithSelector(LendingCoreV1.LendingCore__UnsupportedToken.selector, address(tokenETH)));
        castLendingProxy.depositCollateral(address(tokenETH), 1e18);
        vm.stopPrank();
    }

    // ========== Withdraw Collateral Tests ==========
    function test_WithdrawCollateral_Half() public {
        uint256 userBalance = 1e18;
        uint256 depositAmount = userBalance;
        uint256 withdrawAmount = depositAmount / 2;

        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _fund(address(tokenBTC), user1, userBalance);
        _approveAndDepositCollateral(user1, address(tokenBTC), depositAmount);

        vm.startPrank(user1);
        vm.expectEmit(true, true, true, true);
        emit CollateralWithdrawn(user1, address(tokenBTC), withdrawAmount);

        castLendingProxy.withdrawCollateral(address(tokenBTC), withdrawAmount);
        vm.stopPrank();

        uint256 remainingAmount = castCollateralManagerProxy.getDepositedCollateral(user1, address(tokenBTC));
        assertEq(tokenBTC.balanceOf(user1), userBalance - depositAmount + withdrawAmount);
        assertEq(remainingAmount, depositAmount - withdrawAmount);
    }

    function test_RevertWhen_WithdrawCollateral_AmountExceedsDeposit() public {
        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _fund(address(tokenBTC), user1, 1e18);
        _approveAndDepositCollateral(user1, address(tokenBTC), 0.5 ether);

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(LendingCoreV1.LendingCore__AmountExceedsLimit.selector, 0.5 ether, 1 ether)
        );
        castLendingProxy.withdrawCollateral(address(tokenBTC), 1 ether);
        vm.stopPrank();
    }

    // ========== Borrow Tests ==========
    function test_Borrow() public {
        uint16 ltv = 5000; // 50%
        uint256 fundLiquidity = 1_000_000e18;
        uint256 fundCollateral = 1e18;

        uint40 minBorrowDuration = 1 days;
        uint40 maxBorrowDuration = 730 days;

        uint256 minBorrowAmount = 1;
        uint256 maxBorrowAmount = fundLiquidity;

        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _setLTV(address(tokenBTC), ltv);
        _setMaxBorrowAmount(address(tokenUSDT), maxBorrowAmount);
        _setMinBorrowAmount(address(tokenUSDT), minBorrowAmount);
        _setMaxBorrowDuration(maxBorrowDuration);
        _setMinBorrowDuration(minBorrowDuration);
        _fund(address(tokenBTC), user1, fundCollateral);
        _fund(address(tokenUSDT), liquidityProvider, fundLiquidity);
        _addLiquidity(address(tokenUSDT), fundLiquidity);
        _approveAndDepositCollateral(user1, address(tokenBTC), fundCollateral);

        uint256 borrowAmount =
            castLendingProxy.getMaxBorrowBeforeInterest(user1, address(tokenUSDT), address(tokenBTC)) / 2;

        vm.startPrank(user1);
        vm.expectEmit(true, true, true, true);
        emit Borrowed(user1, address(tokenUSDT), borrowAmount, address(tokenBTC));

        castLendingProxy.borrow(address(tokenUSDT), borrowAmount, address(tokenBTC), 30 days);
        vm.stopPrank();

        LendingCoreV1.Loan memory loan = castLendingProxy.getUserLoan(user1, address(tokenBTC));
        assertEq(loan.borrowToken, address(tokenUSDT));
        assertTrue(loan.principal + loan.interestAccrued > borrowAmount);
        assertTrue(loan.active);
    }

    function test_RevertWhen_Borrow_ExceedsMaxBorrowAfterInterest() public {
        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _setLTV(address(tokenBTC), 5000);
        _setMaxBorrowDuration(30 days);
        _fund(address(tokenBTC), user1, 1e18);
        _fund(address(tokenUSDT), liquidityProvider, 1_000_000e18);
        _addLiquidity(address(tokenUSDT), 1_000_000e18);
        _approveAndDepositCollateral(user1, address(tokenBTC), 1e18);

        uint256 maxBeforeInterest =
            castLendingProxy.getMaxBorrowBeforeInterest(user1, address(tokenUSDT), address(tokenBTC));

        vm.startPrank(user1);
        vm.expectRevert();
        castLendingProxy.borrow(address(tokenUSDT), maxBeforeInterest + 1, address(tokenBTC), 30 days);
        vm.stopPrank();
    }

    // ========== Repay Tests ==========
    function test_Repay_Full() public {
        uint16 ltv = 5000; // 50%
        uint256 fundLiquidity = 1_000_000e18;
        uint256 fundCollateral = 1e18;

        uint40 minBorrowDuration = 1 days;
        uint40 maxBorrowDuration = 730 days;

        uint256 minBorrowAmount = 1;
        uint256 maxBorrowAmount = fundLiquidity;

        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _setLTV(address(tokenBTC), ltv);
        _setMaxBorrowAmount(address(tokenUSDT), maxBorrowAmount);
        _setMinBorrowAmount(address(tokenUSDT), minBorrowAmount);
        _setMaxBorrowDuration(maxBorrowDuration);
        _setMinBorrowDuration(minBorrowDuration);
        _fund(address(tokenBTC), user1, fundCollateral);
        _fund(address(tokenUSDT), liquidityProvider, fundLiquidity);
        _addLiquidity(address(tokenUSDT), fundLiquidity);
        _approveAndDepositCollateral(user1, address(tokenBTC), fundCollateral);

        uint256 borrowAmount =
            castLendingProxy.getMaxBorrowBeforeInterest(user1, address(tokenUSDT), address(tokenBTC)) / 2;

        vm.startPrank(user1);
        castLendingProxy.borrow(address(tokenUSDT), borrowAmount, address(tokenBTC), 30 days);
        vm.stopPrank();

        uint256 interest = castLendingProxy.getUserLoan(user1, address(tokenBTC)).interestAccrued;
        uint256 repayAmount = borrowAmount + interest;
        _fund(address(tokenUSDT), user1, repayAmount);

        vm.startPrank(user1);
        IERC20Metadata(address(tokenUSDT)).approve(address(lendingProxy), repayAmount);
        vm.expectEmit(true, true, true, true);
        emit Repaid(user1, address(tokenBTC), repayAmount);
        castLendingProxy.repay(address(tokenBTC), repayAmount);
        vm.stopPrank();

        LendingCoreV1.Loan memory loanAfter = castLendingProxy.getUserLoan(user1, address(tokenBTC));
        assertFalse(loanAfter.active);
        assertEq(loanAfter.principal, 0);
    }

    // ========== Liquidate Tests ==========
    function test_Liquidate() public {
        uint16 ltv = 7000;
        uint16 liquidationPenalty = 500;

        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _setLTV(address(tokenBTC), ltv);
        _setMaxBorrowDuration(730 days);
        _setMinBorrowDuration(1 days);
        _setLiquidationPenalty(address(tokenBTC), liquidationPenalty);

        {
            uint256 depositAmount = 1e18;
            _fund(address(tokenBTC), user1, depositAmount);
            _approveAndDepositCollateral(user1, address(tokenBTC), depositAmount);
        }

        {
            uint256 fundLiquidity = 100_000e18;
            _setMaxBorrowAmount(address(tokenUSDT), fundLiquidity);
            _setMinBorrowAmount(address(tokenUSDT), 1);
            _fund(address(tokenUSDT), liquidityProvider, fundLiquidity);
            _addLiquidity(address(tokenUSDT), fundLiquidity);
        }

        {
            vm.startPrank(user1);
            uint40 borrowDuration = 30 days;
            uint256 borrowAmount = Math.mulDiv(
                castLendingProxy.getMaxBorrowBeforeInterest(user1, address(tokenUSDT), address(tokenBTC)),
                BPS_DENOMINATOR,
                BPS_DENOMINATOR + castLendingProxy.getCurrentInterestRateBPS(address(tokenUSDT), borrowDuration)
            );
            castLendingProxy.borrow(address(tokenUSDT), borrowAmount, address(tokenBTC), borrowDuration);
            vm.stopPrank();
        }

        {
            vm.startPrank(oracleHandler);
            tellorOracle.submitValue(QUERY_ID_BTC, abi.encode(PRICE_BTC - (PRICE_BTC / 5)), 0, QUERY_DATA_BTC);
            vm.warp(block.timestamp + DISPUTE_BUFFER + 1);
            vm.stopPrank();
        }

        uint256 expectedSeizeAmount;
        {
            vm.startPrank(liquidator);
            (uint256 principal, uint256 interestAccrued, uint256 repaid,, address borrowToken,,,) =
                castLendingProxy.s_userLoans(user1, address(tokenBTC));

            uint256 userRemainingDebt = principal + interestAccrued - repaid;
            uint256 userDebtUsd = priceOracle.getValue(borrowToken, userRemainingDebt);

            uint256 repayAmountUsd = Math.mulDiv(
                userDebtUsd, BPS_DENOMINATOR, Math.mulDiv(ltv, BPS_DENOMINATOR + liquidationPenalty, BPS_DENOMINATOR)
            );
            if (repayAmountUsd > userDebtUsd) {
                repayAmountUsd = userDebtUsd;
            }

            uint256 penaltyUsd = Math.mulDiv(repayAmountUsd, liquidationPenalty, BPS_DENOMINATOR);
            uint256 totalSeizeUsd = repayAmountUsd + penaltyUsd;
            expectedSeizeAmount = _usdToTokenAmount(totalSeizeUsd, address(tokenBTC));

            vm.expectEmit(true, true, false, true);
            emit Liquidated(user1, address(tokenBTC), expectedSeizeAmount);
            castLendingProxy.liquidate(user1, address(tokenBTC));
            vm.stopPrank();
        }

        LendingCoreV1.Loan memory loanAfter = castLendingProxy.getUserLoan(user1, address(tokenBTC));
        assertGt(loanAfter.repaidAmount, 0);
        assertEq(loanAfter.totalLiquidated, expectedSeizeAmount);
        assertLt(castCollateralManagerProxy.getDepositedCollateral(user1, address(tokenBTC)), 1e18);
    }

    // ========== Liquidity Management Tests ==========
    function test_AddLiquidity() public {
        uint256 fundLiquidity = 1_000_000e18;
        uint256 addAmount = fundLiquidity / 2;

        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _fund(address(tokenUSDT), liquidityProvider, fundLiquidity);
        _addLiquidity(address(tokenUSDT), addAmount);

        assertEq(tokenUSDT.balanceOf(address(lendingProxy)), addAmount);
    }

    function test_RemoveLiquidity_Full() public {
        uint256 fundLiquidity = 1_000_000e18;
        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _fund(address(tokenUSDT), liquidityProvider, fundLiquidity);
        _addLiquidity(address(tokenUSDT), fundLiquidity);

        vm.startPrank(liquidityProvider);
        castLendingProxy.removeLiquidity(address(tokenUSDT), fundLiquidity);
        vm.stopPrank();

        assertEq(tokenUSDT.balanceOf(liquidityProvider), fundLiquidity);
        assertEq(tokenUSDT.balanceOf(address(lendingProxy)), 0);
    }

    // ========== Token Management Tests ==========
    function test_AddBorrowToken() public {
        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));

        assertTrue(castLendingProxy.s_isBorrowTokenSupported(address(tokenUSDT)));
        assertEq(castLendingProxy.s_borrowTokens(0), address(tokenUSDT));
    }

    // ========== Parameter Management Tests ==========
    function test_SetLTV() public {
        uint16 ltvRatio = 5000; // 50%
        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _setLTV(address(tokenBTC), ltvRatio);

        assertEq(castLendingProxy.s_ltvBPS(address(tokenBTC)), ltvRatio);
    }

    // ========== Pause Tests ==========
    function test_PauseUnpause() public {
        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _fund(address(tokenBTC), user1, 1e18);

        vm.startPrank(pauser);
        castLendingProxy.pause();
        assertTrue(castLendingProxy.paused());

        // Try to deposit while paused
        vm.startPrank(user1);
        tokenBTC.approve(address(castLendingProxy), 1e18);
        vm.expectRevert();
        castLendingProxy.depositCollateral(address(tokenBTC), 1e18);
        vm.stopPrank();

        // Unpause
        vm.startPrank(pauser);
        castLendingProxy.unpause();
        vm.stopPrank();

        // Verify can deposit after unpause
        vm.startPrank(user1);
        tokenBTC.approve(address(castLendingProxy), 1e18);
        castLendingProxy.depositCollateral(address(tokenBTC), 1e18);
        vm.stopPrank();

        assertFalse(castLendingProxy.paused());
    }

    // ========== View Function Tests ==========
    function test_GetAvailableSupply() public {
        uint256 fundLiquidity = 1000e18;
        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _fund(address(tokenUSDT), liquidityProvider, fundLiquidity);
        _addLiquidity(address(tokenUSDT), fundLiquidity);

        assertEq(castLendingProxy.getAvailableSupply(address(tokenUSDT)), fundLiquidity);
    }

    // ========== Upgrade Tests ==========
    function test_UpgradeToAndCall() public {
        MockLendingCoreV2 newImpl = new MockLendingCoreV2();
        uint256 setNum = 888;

        vm.startPrank(upgrader);
        castLendingProxy.upgradeToAndCall(address(newImpl), "");
        vm.stopPrank();

        MockLendingCoreV2 upgradedProxy = MockLendingCoreV2(address(castLendingProxy));
        vm.startPrank(user1);
        upgradedProxy.setNum(setNum);
        assertEq(upgradedProxy.getNum(), setNum);
        vm.stopPrank();
    }
}
