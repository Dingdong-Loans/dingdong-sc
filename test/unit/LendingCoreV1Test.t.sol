// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {LendingCore} from "../../src/core/LendingCoreV1.sol";
import {CollateralManager} from "../../src/core/CollateralManager.sol";
import {InterestRateModel} from "../../src/core/InterestRateModel.sol";
import {PriceOracle} from "../../src/core/PriceOracle.sol";
import {TellorUser} from "../../src/tellor/TellorUser.sol";
import {TellorPlayground} from "@tellor/contracts/TellorPlayground.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

contract LendingCoreV1Test is Test {
    string constant USD = "usd";
    string constant USDT = "usdt";
    string constant IDRX = "idrx";
    string constant BTC = "btc";
    string constant ETH = "eth";

    string constant queryType = "SpotPrice";

    bytes constant queryDataUSDT = abi.encode(queryType, abi.encode(USDT, USD));
    bytes constant queryDataIDRX = abi.encode(queryType, abi.encode(IDRX, USD));
    bytes constant queryDataBTC = abi.encode(queryType, abi.encode(BTC, USD));
    bytes constant queryDataETH = abi.encode(queryType, abi.encode(ETH, USD));
    bytes32 constant queryIdUSDT = keccak256(queryDataUSDT);
    bytes32 constant queryIdIDRX = keccak256(queryDataIDRX);
    bytes32 constant queryIdBTC = keccak256(queryDataBTC);
    bytes32 constant queryIdETH = keccak256(queryDataETH);

    ERC1967Proxy public lendingProxy;
    LendingCore public lending;
    LendingCore public castLendingProxy;

    ERC1967Proxy public collateralManagerProxy;
    CollateralManager public collateralManager;
    CollateralManager public castCollateralManagerProxy;

    InterestRateModel public interestRateModel;
    PriceOracle public priceOracle;

    MockERC20 public tokenUSDT;
    MockERC20 public tokenIDRX;
    MockERC20 public tokenBTC;
    MockERC20 public tokenETH;

    TellorPlayground tellorOracle;
    uint256 public constant DISPUTE_BUFFER = 20 minutes;
    uint256 public constant STALENESS_AGE = 2 hours;
    TellorUser pricefeedUSDT;
    TellorUser pricefeedIDRX;
    TellorUser pricefeedBTC;
    TellorUser pricefeedETH;

    /// @dev mock price value with 8 decimal
    uint256 priceUSDT = 1e8;
    uint256 priceIDRX = 6042;
    uint256 priceBTC = 100000e8;
    uint256 priceETH = 2500e8;

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

    function setUp() public {
        vm.startPrank(admin);
        // initialize LendingCore
        bytes memory initializeLendingData = abi.encodeWithSelector(
            LendingCore.initialize.selector,
            admin,
            [pauser, upgrader, parameterManager, tokenManager, liquidityProvider, liquidator]
        );
        lending = new LendingCore();
        lendingProxy = new ERC1967Proxy(address(lending), initializeLendingData);
        castLendingProxy = LendingCore(address(lendingProxy));

        // initialize CollateralManager
        bytes memory initializeCollateralManagerData =
            abi.encodeWithSelector(CollateralManager.initialize.selector, address(lendingProxy));
        collateralManager = new CollateralManager();
        collateralManagerProxy = new ERC1967Proxy(address(collateralManager), initializeCollateralManagerData);
        castCollateralManagerProxy = CollateralManager(address(collateralManagerProxy));

        // initialize PriceOracle
        priceOracle = new PriceOracle(address(lendingProxy));
        // initialize InterestRateModel
        interestRateModel = new InterestRateModel(address(lendingProxy));
        vm.stopPrank();

        vm.startPrank(upgrader);
        // set CollateralManager in LendingCore
        castLendingProxy.setCollateralManager(address(collateralManagerProxy));
        // set InterestRateModel in LendingCore
        castLendingProxy.setInterestRateModel(address(interestRateModel));
        // set PriceOracle in LendingCore
        castLendingProxy.setPriceOracle(address(priceOracle));
        vm.stopPrank();
    }

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

        tellorOracle.submitValue(queryIdUSDT, abi.encode(priceUSDT), 0, queryDataUSDT);
        tellorOracle.submitValue(queryIdIDRX, abi.encode(priceIDRX), 0, queryDataIDRX);
        tellorOracle.submitValue(queryIdBTC, abi.encode(priceBTC), 0, queryDataBTC);
        tellorOracle.submitValue(queryIdETH, abi.encode(priceETH), 0, queryDataETH);

        // ensure value pass dispute buffer
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

    function test_checkInitialization() public view {
        // Check that roles are properly assigned
        assertTrue(castLendingProxy.hasRole(castLendingProxy.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(castLendingProxy.hasRole(castLendingProxy.PAUSER_ROLE(), pauser));
        assertTrue(castLendingProxy.hasRole(castLendingProxy.UPGRADER_ROLE(), upgrader));
        assertTrue(castLendingProxy.hasRole(castLendingProxy.PARAMETER_MANAGER_ROLE(), parameterManager));
        assertTrue(castLendingProxy.hasRole(castLendingProxy.TOKEN_MANAGER_ROLE(), tokenManager));
        assertTrue(castLendingProxy.hasRole(castLendingProxy.LIQUIDITY_PROVIDER_ROLE(), liquidityProvider));
        assertTrue(castLendingProxy.hasRole(castLendingProxy.LIQUIDATOR_ROLE(), liquidator));

        // Check that the contract is not paused after initialization
        assertFalse(castLendingProxy.paused());

        // Check that the BPS denominator is set correctly
        assertEq(castLendingProxy.BPS_DENOMINATOR(), 10000);

        // Check that modules are set correctly
        assertEq(address(castLendingProxy.s_collateralManager()), address(collateralManagerProxy));
        assertEq(address(castLendingProxy.s_interestRateModel()), address(interestRateModel));
        assertEq(address(castLendingProxy.s_priceOracle()), address(priceOracle));
    }

    function test_depositCollateral() public {
        uint256 userBalance = 1e18;

        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _fund(address(tokenBTC), user1, userBalance);

        // deposit half user balance
        uint256 depositAmount = userBalance / 2;
        _approveAndDepositCollateral(user1, address(tokenBTC), depositAmount);

        uint256 depositedAmount = castCollateralManagerProxy.getDepositedCollateral(user1, address(tokenBTC));
        assertEq(depositedAmount, depositAmount);
    }

    function test_withdrawCollateral_full() public {
        uint256 userBalance = 1e18;

        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _fund(address(tokenBTC), user1, userBalance);

        uint256 depositAmount = userBalance;
        _approveAndDepositCollateral(user1, address(tokenBTC), depositAmount);

        // withdraw all deposited amount
        uint256 withdrawAmount = depositAmount;

        vm.startPrank(user1);
        castLendingProxy.withdrawCollateral(address(tokenBTC), withdrawAmount);
        vm.stopPrank();

        uint256 remainingAmount = castCollateralManagerProxy.getDepositedCollateral(user1, address(tokenBTC));
        assertEq(tokenBTC.balanceOf(user1), userBalance - depositAmount + withdrawAmount);
        assertEq(remainingAmount, depositAmount - withdrawAmount);
    }

    function test_withdrawCollateral_half() public {
        uint256 userBalance = 1e18;

        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _fund(address(tokenBTC), user1, userBalance);

        uint256 depositAmount = userBalance;
        _approveAndDepositCollateral(user1, address(tokenBTC), depositAmount);

        // withdraw half deposited amount
        uint256 withdrawAmount = depositAmount / 2;

        vm.startPrank(user1);
        castLendingProxy.withdrawCollateral(address(tokenBTC), withdrawAmount);
        vm.stopPrank();

        uint256 remainingAmount = castCollateralManagerProxy.getDepositedCollateral(user1, address(tokenBTC));
        assertEq(tokenBTC.balanceOf(user1), userBalance - depositAmount + withdrawAmount);
        assertEq(remainingAmount, depositAmount - withdrawAmount);
    }

    function test_borrow() public {
        uint16 ltv = 5000; // 50%
        uint256 fundLiquidity = 1000000e18; // 1.000.000 USDT
        uint256 fundCollateral = 1e18; // 1 BTC

        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _setLTV(address(tokenBTC), ltv);
        _setMaxBorrowDuration(730 days);
        _fund(address(tokenBTC), user1, fundCollateral);
        _fund(address(tokenUSDT), liquidityProvider, fundLiquidity);
        _addLiquidity(address(tokenUSDT), fundLiquidity);
        _approveAndDepositCollateral(user1, address(tokenBTC), fundCollateral);

        // borrow half max borrow (before interest applied)
        uint256 borrowAmount =
            castLendingProxy.getMaxBorrowBeforeInterest(user1, address(tokenUSDT), address(tokenBTC)) / 2;
        vm.startPrank(user1);
        castLendingProxy.borrow(address(tokenUSDT), borrowAmount, address(tokenBTC), 30 days);
        vm.stopPrank();

        LendingCore.Loan memory loan = castLendingProxy.getUserLoan(user1, address(tokenBTC));
        assertEq(loan.borrowToken, address(tokenUSDT));
        assertEq((loan.principal + loan.interestAccrued) > borrowAmount, true);
        assertTrue(loan.active);
    }

    function test_repay_half() public {
        uint16 ltv = 5000; // 50%
        uint256 fundLiquidity = 1000000e18; // 1.000.000 USDT
        uint256 fundCollateral = 1e18; // 1 BTC

        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _setLTV(address(tokenBTC), ltv);
        _setMaxBorrowDuration(730 days);
        _fund(address(tokenBTC), user1, fundCollateral);
        _fund(address(tokenUSDT), liquidityProvider, fundLiquidity);
        _addLiquidity(address(tokenUSDT), fundLiquidity);
        _approveAndDepositCollateral(user1, address(tokenBTC), fundCollateral);

        uint256 borrowAmount =
            castLendingProxy.getMaxBorrowBeforeInterest(user1, address(tokenUSDT), address(tokenBTC)) / 2;
        vm.startPrank(user1);
        castLendingProxy.borrow(address(tokenUSDT), borrowAmount, address(tokenBTC), 30 days);
        vm.stopPrank();

        _fund(address(tokenUSDT), user1, borrowAmount);
        LendingCore.Loan memory loanBefore = castLendingProxy.getUserLoan(user1, address(tokenBTC));

        uint256 repayAmount = borrowAmount;
        vm.startPrank(user1);
        IERC20Metadata(address(tokenUSDT)).approve(address(lendingProxy), repayAmount);
        castLendingProxy.repay(address(tokenBTC), repayAmount);
        vm.stopPrank();

        LendingCore.Loan memory loanAfter = castLendingProxy.getUserLoan(user1, address(tokenBTC));
        assertEq(loanAfter.repaidAmount, loanBefore.repaidAmount + repayAmount);
    }

    function test_repay_full() public {
        uint16 ltv = 5000; // 50%
        uint256 fundLiquidity = 1000000e18; // 1.000.000 USDT
        uint256 fundCollateral = 1e18; // 1 BTC

        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _setLTV(address(tokenBTC), ltv);
        _setMaxBorrowDuration(730 days);
        _fund(address(tokenBTC), user1, fundCollateral);
        _fund(address(tokenUSDT), liquidityProvider, fundLiquidity);
        _addLiquidity(address(tokenUSDT), fundLiquidity);
        _approveAndDepositCollateral(user1, address(tokenBTC), fundCollateral);

        uint256 borrowAmount =
            castLendingProxy.getMaxBorrowBeforeInterest(user1, address(tokenUSDT), address(tokenBTC)) / 2;
        vm.startPrank(user1);
        castLendingProxy.borrow(address(tokenUSDT), borrowAmount, address(tokenBTC), 30 days);
        vm.stopPrank();

        _fund(address(tokenUSDT), user1, borrowAmount);

        // repay borrowAmount + interest = full repayment
        uint256 repayAmount = borrowAmount + castLendingProxy.getUserLoan(user1, address(tokenBTC)).interestAccrued;
        vm.startPrank(user1);
        IERC20Metadata(address(tokenUSDT)).approve(address(lendingProxy), repayAmount);
        castLendingProxy.repay(address(tokenBTC), repayAmount);
        vm.stopPrank();

        LendingCore.Loan memory loanAfter = castLendingProxy.getUserLoan(user1, address(tokenBTC));

        // check if loan information resets immediately after full repayment
        assertEq(loanAfter.principal, 0);
        assertEq(loanAfter.interestAccrued, 0);
        assertEq(loanAfter.interestRateBPS, 0);
        assertEq(loanAfter.repaidAmount, 0);
        assertEq(loanAfter.totalLiquidated, 0);
        assertEq(loanAfter.borrowToken, address(0));
        assertEq(loanAfter.startTime, 0);
        assertEq(loanAfter.dueDate, 0);
        assertFalse(loanAfter.active);
    }

    function test_addLiquidity_half() public {
        uint256 fundLiquidity = 1000000e18; // 1.000.000 USDT

        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _fund(address(tokenUSDT), liquidityProvider, fundLiquidity);

        uint256 addAmount = fundLiquidity / 2;
        _addLiquidity(address(tokenUSDT), addAmount);

        uint256 balance = IERC20Metadata(address(tokenUSDT)).balanceOf(address(lendingProxy));
        assertEq(balance, addAmount);
    }

    function test_addLiquidity_full() public {
        uint256 fundLiquidity = 1000000e18; // 1.000.000 USDT

        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _fund(address(tokenUSDT), liquidityProvider, fundLiquidity);

        uint256 addAmount = fundLiquidity;
        _addLiquidity(address(tokenUSDT), addAmount);

        uint256 balance = tokenUSDT.balanceOf(address(lendingProxy));
        assertEq(balance, addAmount);
    }

    function test_removeLiquidity_half() public {
        uint256 fundLiquidity = 1000000e18; // 1.000.000 USDT

        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _fund(address(tokenUSDT), liquidityProvider, fundLiquidity);
        _addLiquidity(address(tokenUSDT), fundLiquidity);

        uint256 removeAmount = fundLiquidity / 2;
        vm.startPrank(liquidityProvider);
        castLendingProxy.removeLiquidity(address(tokenUSDT), removeAmount);
        vm.stopPrank();

        uint256 providerBalance = tokenUSDT.balanceOf(liquidityProvider);
        uint256 protocolBalance = tokenUSDT.balanceOf(address(lendingProxy));
        assertEq(removeAmount, providerBalance);
        assertEq(protocolBalance, removeAmount); // other half
    }

    function test_removeLiquidity_full() public {
        uint256 fundLiquidity = 1000000e18; // 1.000.000 USDT

        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _fund(address(tokenUSDT), liquidityProvider, fundLiquidity);
        _addLiquidity(address(tokenUSDT), fundLiquidity);

        uint256 removeAmount = fundLiquidity;
        vm.startPrank(liquidityProvider);
        castLendingProxy.removeLiquidity(address(tokenUSDT), removeAmount);
        vm.stopPrank();

        uint256 providerBalance = tokenUSDT.balanceOf(liquidityProvider);
        uint256 protocolBalance = tokenUSDT.balanceOf(address(lendingProxy));

        assertEq(removeAmount, providerBalance);
        assertEq(protocolBalance, 0);
    }

    function test_addBorrowToken() public {
        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));

        bool isSupported = castLendingProxy.s_isBorrowTokenSupported(address(tokenUSDT));
        address addedToken = castLendingProxy.s_borrowTokens(0);
        assertEq(isSupported, true);
        assertEq(addedToken, address(tokenUSDT));
    }

    function test_removeBorrowToken() public {
        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));

        vm.startPrank(tokenManager);
        castLendingProxy.removeBorrowToken(address(tokenUSDT));
        vm.stopPrank();

        bool isSupported = castLendingProxy.s_isBorrowTokenSupported(address(tokenUSDT));
        uint256 tokenCount = castLendingProxy.getBorrowTokens().length;
        assertEq(isSupported, false);
        assertEq(tokenCount, 0);
    }

    function test_addCollateralToken() public {
        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));

        bool isSupported = castCollateralManagerProxy.s_isCollateralTokenSupported(address(tokenBTC));
        address addedToken = castCollateralManagerProxy.s_collateralTokens(0);
        assertEq(isSupported, true);
        assertEq(addedToken, address(tokenBTC));
    }

    function test_removeCollateralToken() public {
        _setupTokensAndPriceFeeds();
        test_addCollateralToken();

        vm.startPrank(tokenManager);
        castLendingProxy.removeCollateralToken(address(tokenBTC));
        vm.stopPrank();

        bool isSupported = castCollateralManagerProxy.s_isCollateralTokenSupported(address(tokenBTC));
        assertEq(isSupported, false);
    }

    function test_setLTV() public {
        uint16 ltvRatio = 5000; // 50%

        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _setLTV(address(tokenBTC), ltvRatio);

        uint16 ltv = castLendingProxy.s_ltvBPS(address(tokenBTC));
        assertEq(ltv, ltvRatio);
    }

    function test_setLiquidationPenalty() public {
        uint16 liquidationPenalty = 1000; // 10%
        _setLiquidationPenalty(address(tokenBTC), liquidationPenalty);

        uint16 penalty = castLendingProxy.s_liquidationPenaltyBPS(address(tokenBTC));
        assertEq(penalty, liquidationPenalty);
    }

    function test_setMaxBorrowDuration() public {
        uint40 durationAmount = 365 days;
        _setMaxBorrowDuration(durationAmount);

        uint64 duration = castLendingProxy.s_maxBorrowDuration();
        assertEq(duration, durationAmount);
    }

    function test_setGracePeriod() public {
        uint40 periodAmount = 7 days;
        _setGracePeriod(periodAmount);

        uint64 period = castLendingProxy.s_gracePeriod();
        assertEq(period, periodAmount);
    }

    function test_pauseUnpause() public {
        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _fund(address(tokenBTC), user1, 1e18);

        vm.startPrank(pauser);
        castLendingProxy.pause();
        vm.stopPrank();

        assertTrue(castLendingProxy.paused());

        // try to deposit collateral while paused
        vm.startPrank(user1);
        tokenBTC.approve(address(castLendingProxy), 1e18);
        vm.expectRevert();
        castLendingProxy.depositCollateral(address(tokenBTC), 1e18);
        vm.stopPrank();

        vm.startPrank(pauser);
        castLendingProxy.unpause();
        vm.stopPrank();

        // try to deposit collateral after unpause
        vm.startPrank(user1);
        tokenBTC.approve(address(castLendingProxy), 1e18);
        castLendingProxy.depositCollateral(address(tokenBTC), 1e18);
        vm.stopPrank();

        assertFalse(castLendingProxy.paused());
    }

    // ========== VIEW FUNCTIONS TESTS =========
    function test_getAvailableSupply() public {
        uint256 fundLiquidity = 1000e18; // 1.000 USDT

        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _fund(address(tokenUSDT), liquidityProvider, fundLiquidity);
        _addLiquidity(address(tokenUSDT), fundLiquidity);

        uint256 availableSupply = castLendingProxy.getAvailableSupply(address(tokenUSDT));
        assertEq(availableSupply, fundLiquidity);
    }

    function test_getTotalSupply() public {
        uint16 ltv = 5000; // 50%
        uint256 fundLiquidity = 1000e18; // 1.000 USDT
        uint256 fundCollateral = 1e18; // 1 BTC

        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _setLTV(address(tokenBTC), ltv);
        _setMaxBorrowDuration(730 days);
        _fund(address(tokenBTC), user1, fundCollateral);
        _fund(address(tokenUSDT), liquidityProvider, fundLiquidity);
        _addLiquidity(address(tokenUSDT), fundLiquidity);
        _approveAndDepositCollateral(user1, address(tokenBTC), fundCollateral);

        vm.startPrank(user1);
        castLendingProxy.borrow(address(tokenUSDT), 100e18, address(tokenBTC), 30 days);
        vm.stopPrank();

        uint256 totalSupply = castLendingProxy.getTotalSupply(address(tokenUSDT));
        uint256 expectedSupply = fundLiquidity + castLendingProxy.getUserLoan(user1, address(tokenBTC)).interestAccrued; // after borrow

        assertEq(totalSupply, expectedSupply);
    }

    // function test_getUtilizationBPS() public {
    //     uint16 ltv = 5000; // 50%
    //     uint256 fundLiquidity = 1000e18; // 1.000 USDT
    //     uint256 fundCollateral = 1e18; // 1 BTC

    //     _setupTokensAndPriceFeeds();
    //     _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
    //     _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
    //     _setLTV(address(tokenBTC), ltv);
    //     _setMaxBorrowDuration(730 days);
    //     _fund(address(tokenBTC), user1, fundCollateral);
    //     _fund(address(tokenUSDT), liquidityProvider, fundLiquidity);
    //     _addLiquidity(address(tokenUSDT), fundLiquidity);
    //     _approveAndDepositCollateral(user1, address(tokenBTC), fundCollateral);

    //     vm.startPrank(user1);
    //     castLendingProxy.borrow(address(tokenUSDT), 100e18, address(tokenBTC), 30 days);
    //     vm.stopPrank();

    //     uint256 utilization = castLendingProxy.getUtilizationBPS(address(tokenUSDT));
    //     assertEq(utilization, 2000);
    // }
}
