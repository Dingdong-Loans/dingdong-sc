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
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
        // initialize LendingCoreV1
        bytes memory initializeLendingData = abi.encodeWithSelector(
            LendingCoreV1.initialize.selector,
            admin,
            [pauser, upgrader, parameterManager, tokenManager, liquidityProvider, liquidator]
        );
        lending = new LendingCoreV1();
        lendingProxy = new ERC1967Proxy(address(lending), initializeLendingData);
        castLendingProxy = LendingCoreV1(address(lendingProxy));

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
        // set CollateralManager in LendingCoreV1
        castLendingProxy.setCollateralManager(address(collateralManagerProxy));
        // set InterestRateModel in LendingCoreV1
        castLendingProxy.setInterestRateModel(address(interestRateModel));
        // set PriceOracle in LendingCoreV1
        castLendingProxy.setPriceOracle(address(priceOracle));
        vm.stopPrank();
    }

    // ========== HELPER TESTs ==========
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

    function _usdToTokenAmount(uint256 _amountUsd, address _token) internal returns (uint256 amount) {
        uint256 tokenDecimals = 10 ** IERC20Metadata(_token).decimals();
        uint256 debtTokenPrice = priceOracle.getValue(_token, tokenDecimals);

        amount = Math.mulDiv(_amountUsd, tokenDecimals, debtTokenPrice);
    }

    function test_initialization() public view {
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

    // ========== depositCollateral TESTs ==========
    function test_depositCollateral() public {
        uint256 userBalance = 1e18;

        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _fund(address(tokenBTC), user1, userBalance);

        uint256 depositAmount = userBalance / 2;

        vm.startPrank(user1);

        tokenBTC.approve(address(lendingProxy), depositAmount);

        vm.expectEmit(true, true, true, true);
        emit LendingCoreV1.CollateralDeposited(user1, address(tokenBTC), depositAmount);

        castLendingProxy.depositCollateral(address(tokenBTC), depositAmount);

        vm.stopPrank();

        uint256 depositedAmount = castCollateralManagerProxy.getDepositedCollateral(user1, address(tokenBTC));
        assertEq(depositedAmount, depositAmount);
    }

    function test_revert_depositCollateral_zeroAddressToken() public {
        uint256 depositAmount = 1e18;

        vm.startPrank(user1);
        vm.expectRevert(LendingCoreV1.LendingCore__InvalidAddress.selector);
        castLendingProxy.depositCollateral(address(0), depositAmount);
        vm.stopPrank();
    }

    function test_revert_depositCollateral_zeroAmount() public {
        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));

        vm.startPrank(user1);
        vm.expectRevert(LendingCoreV1.LendingCore__ZeroAmountNotAllowed.selector);
        castLendingProxy.depositCollateral(address(tokenBTC), 0);
        vm.stopPrank();
    }

    function test_revert_depositCollateral_unsupportedToken() public {
        // Assume tokenETH is not added to supported collateral tokens
        _setupTokensAndPriceFeeds();
        _fund(address(tokenETH), user1, 1e18);

        vm.startPrank(user1);
        tokenETH.approve(address(castLendingProxy), 1e18);
        vm.expectRevert(abi.encodeWithSelector(LendingCoreV1.LendingCore__UnsupportedToken.selector, address(tokenETH)));
        castLendingProxy.depositCollateral(address(tokenETH), 1e18);
        vm.stopPrank();
    }

    // ========== withdrawCollateral TESTs ==========
    function test_withdrawCollateral_half() public {
        uint256 userBalance = 1e18;

        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _fund(address(tokenBTC), user1, userBalance);

        uint256 depositAmount = userBalance;
        _approveAndDepositCollateral(user1, address(tokenBTC), depositAmount);

        uint256 withdrawAmount = depositAmount / 2;

        vm.startPrank(user1);

        vm.expectEmit(true, true, true, true);
        emit LendingCoreV1.CollateralWithdrawn(user1, address(tokenBTC), withdrawAmount);

        castLendingProxy.withdrawCollateral(address(tokenBTC), withdrawAmount);
        vm.stopPrank();

        uint256 remainingAmount = castCollateralManagerProxy.getDepositedCollateral(user1, address(tokenBTC));
        assertEq(tokenBTC.balanceOf(user1), userBalance - depositAmount + withdrawAmount);
        assertEq(remainingAmount, depositAmount - withdrawAmount);
    }

    function test_withdrawCollateral_full() public {
        uint256 userBalance = 1e18;

        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _fund(address(tokenBTC), user1, userBalance);

        uint256 depositAmount = userBalance;
        _approveAndDepositCollateral(user1, address(tokenBTC), depositAmount);

        uint256 withdrawAmount = depositAmount;

        vm.startPrank(user1);

        vm.expectEmit(true, true, true, true);
        emit LendingCoreV1.CollateralWithdrawn(user1, address(tokenBTC), withdrawAmount);

        castLendingProxy.withdrawCollateral(address(tokenBTC), withdrawAmount);
        vm.stopPrank();

        uint256 remainingAmount = castCollateralManagerProxy.getDepositedCollateral(user1, address(tokenBTC));
        assertEq(tokenBTC.balanceOf(user1), userBalance - depositAmount + withdrawAmount);
        assertEq(remainingAmount, 0);
    }

    function test_revert_withdrawCollateral_zeroAddressToken() public {
        vm.startPrank(user1);
        vm.expectRevert(LendingCoreV1.LendingCore__InvalidAddress.selector);
        castLendingProxy.withdrawCollateral(address(0), 1e18);
        vm.stopPrank();
    }

    function test_revert_withdrawCollateral_zeroAmount() public {
        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));

        vm.startPrank(user1);
        vm.expectRevert(LendingCoreV1.LendingCore__ZeroAmountNotAllowed.selector);
        castLendingProxy.withdrawCollateral(address(tokenBTC), 0);
        vm.stopPrank();
    }

    function test_revert_withdrawCollateral_unsupportedToken() public {
        _setupTokensAndPriceFeeds(); // tokenETH is NOT added
        _fund(address(tokenETH), user1, 1e18);

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(LendingCoreV1.LendingCore__UnsupportedToken.selector, address(tokenETH)));
        castLendingProxy.withdrawCollateral(address(tokenETH), 1e18);
        vm.stopPrank();
    }

    function test_revert_withdrawCollateral_amountExceedsDeposit() public {
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

    function test_revert_withdrawCollateral_healthFactorTooLow() public {
        uint16 ltv = 5000; // 50%
        uint256 fundLiquidity = 1_000_000e18; // 1,000,000 USDT
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

        uint256 BPS_DENOMINATOR = 10000;
        uint40 borrowDuration = 30 days;
        // Borrow max borrow
        uint256 borrowAmount = Math.mulDiv(
            castLendingProxy.getMaxBorrowBeforeInterest(user1, address(tokenUSDT), address(tokenBTC)),
            BPS_DENOMINATOR,
            BPS_DENOMINATOR + castLendingProxy.getCurrentInterestRateBPS(address(tokenUSDT), borrowDuration)
        );

        // try withdraw half of collateal
        uint256 withdrawAmount = fundCollateral / 2;

        vm.startPrank(user1);
        castLendingProxy.borrow(address(tokenUSDT), borrowAmount, address(tokenBTC), borrowDuration);
        vm.stopPrank();

        // Try withdrawing any collateral
        vm.startPrank(user1);
        vm.expectRevert(LendingCoreV1.LendingCore__LoanIsActive.selector);
        castLendingProxy.withdrawCollateral(address(tokenBTC), withdrawAmount);
        vm.stopPrank();
    }

    // ========== borrow TESTs ==========
    function test_borrow() public {
        uint16 ltv = 5000; // 50%
        uint256 fundLiquidity = 1_000_000e18;
        uint256 fundCollateral = 1e18;

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

        vm.expectEmit(true, true, true, true);
        emit LendingCoreV1.Borrowed(user1, address(tokenUSDT), borrowAmount, address(tokenBTC));

        castLendingProxy.borrow(address(tokenUSDT), borrowAmount, address(tokenBTC), 30 days);

        vm.stopPrank();

        LendingCoreV1.Loan memory loan = castLendingProxy.getUserLoan(user1, address(tokenBTC));
        assertEq(loan.borrowToken, address(tokenUSDT));
        assertTrue(loan.principal + loan.interestAccrued > borrowAmount);
        assertTrue(loan.active);
    }

    function test_revert_borrow_zeroAddressBorrowToken() public {
        vm.startPrank(user1);
        vm.expectRevert(LendingCoreV1.LendingCore__InvalidAddress.selector);
        castLendingProxy.borrow(address(0), 1e18, address(tokenBTC), 30 days);
        vm.stopPrank();
    }

    function test_revert_borrow_zeroAddressCollateralToken() public {
        vm.startPrank(user1);
        vm.expectRevert(LendingCoreV1.LendingCore__InvalidAddress.selector);
        castLendingProxy.borrow(address(tokenUSDT), 1e18, address(0), 30 days);
        vm.stopPrank();
    }

    function test_revert_borrow_zeroAmount() public {
        uint256 fundLiquidity = 1_000_000e18; // 1,000,000 USDT
        uint256 fundCollateral = 1e18; // 1 BTC
        uint40 maxBorrowDuration = 30 days;

        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _setMaxBorrowDuration(maxBorrowDuration);
        _fund(address(tokenUSDT), liquidityProvider, fundLiquidity);
        _addLiquidity(address(tokenUSDT), fundLiquidity);
        _fund(address(tokenBTC), user1, fundCollateral);
        _approveAndDepositCollateral(user1, address(tokenBTC), fundCollateral);

        vm.startPrank(user1);
        vm.expectRevert(LendingCoreV1.LendingCore__ZeroAmountNotAllowed.selector);
        castLendingProxy.borrow(address(tokenUSDT), 0, address(tokenBTC), 30 days);
        vm.stopPrank();
    }

    function test_revert_borrow_durationTooShort() public {
        uint256 fundLiquidity = 1_000_000e18; // 1,000,000 USDT
        uint256 fundCollateral = 1e18; // 1 BTC
        uint40 maxBorrowDuration = 30 days;

        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _setMaxBorrowDuration(maxBorrowDuration);
        _fund(address(tokenUSDT), liquidityProvider, fundLiquidity);
        _addLiquidity(address(tokenUSDT), fundLiquidity);
        _fund(address(tokenBTC), user1, fundCollateral);
        _approveAndDepositCollateral(user1, address(tokenBTC), fundCollateral);

        vm.startPrank(user1);
        vm.expectRevert(LendingCoreV1.LendingCore__ZeroAmountNotAllowed.selector);
        castLendingProxy.borrow(address(tokenUSDT), 1e18, address(tokenBTC), 1 hours);
        vm.stopPrank();
    }

    function test_revert_borrow_durationTooLong() public {
        uint256 fundLiquidity = 1_000_000e18; // 1,000,000 USDT
        uint256 fundCollateral = 1e18; // 1 BTC
        uint40 maxBorrowDuration = 30 days;

        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _setMaxBorrowDuration(maxBorrowDuration);
        _fund(address(tokenUSDT), liquidityProvider, fundLiquidity);
        _addLiquidity(address(tokenUSDT), fundLiquidity);
        _fund(address(tokenBTC), user1, fundCollateral);
        _approveAndDepositCollateral(user1, address(tokenBTC), fundCollateral);

        uint40 borrowDuration = 100 days;
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                LendingCoreV1.LendingCore__DurationExceedsLimit.selector, maxBorrowDuration, borrowDuration
            )
        );
        castLendingProxy.borrow(address(tokenUSDT), 1e18, address(tokenBTC), borrowDuration);
        vm.stopPrank();
    }

    function test_revert_borrow_unsupportedCollateralToken() public {
        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT)); // only borrow token added

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(LendingCoreV1.LendingCore__UnsupportedToken.selector, address(tokenBTC)));
        castLendingProxy.borrow(address(tokenUSDT), 1e18, address(tokenBTC), 30 days);
        vm.stopPrank();
    }

    function test_revert_borrow_unsupportedBorrowToken() public {
        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC)); // only collateral token added

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(LendingCoreV1.LendingCore__UnsupportedToken.selector, address(tokenUSDT))
        );
        castLendingProxy.borrow(address(tokenUSDT), 1e18, address(tokenBTC), 30 days);
        vm.stopPrank();
    }

    function test_revert_borrow_insufficientLiquidity() public {
        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));

        _setMaxBorrowDuration(730 days);
        _fund(address(tokenBTC), user1, 1e18);
        _approveAndDepositCollateral(user1, address(tokenBTC), 1e18);

        // Don't add liquidity
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(LendingCoreV1.LendingCore__InsufficientBalance.selector, address(tokenUSDT), 0)
        );
        castLendingProxy.borrow(address(tokenUSDT), 1e18, address(tokenBTC), 30 days);
        vm.stopPrank();
    }

    function test_revert_borrow_existingLoan() public {
        uint256 fundLiquidity = 1_000_000e18; // 1,000,000 USDT
        uint256 fundCollateral = 1e18; // 1 BTC
        uint40 maxBorrowDuration = 30 days;
        uint16 ltv = 5000; // 50%

        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _setLTV(address(tokenBTC), ltv);
        _setMaxBorrowDuration(maxBorrowDuration);
        _fund(address(tokenUSDT), liquidityProvider, fundLiquidity);
        _addLiquidity(address(tokenUSDT), fundLiquidity);
        _fund(address(tokenBTC), user1, fundCollateral);
        _approveAndDepositCollateral(user1, address(tokenBTC), fundCollateral);

        uint256 borrowAmount =
            castLendingProxy.getMaxBorrowBeforeInterest(user1, address(tokenUSDT), address(tokenBTC)) / 2;

        vm.startPrank(user1);
        castLendingProxy.borrow(address(tokenUSDT), borrowAmount, address(tokenBTC), 30 days);

        vm.expectRevert(LendingCoreV1.LendingCore__LoanIsActive.selector);
        castLendingProxy.borrow(address(tokenUSDT), borrowAmount, address(tokenBTC), 30 days);
        vm.stopPrank();
    }

    function test_revert_borrow_exceedsMaxBorrowAfterInterest() public {
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

        // Borrow slightly above limit
        uint256 excessiveAmount = maxBeforeInterest + 1 ether;

        vm.startPrank(user1);
        vm.expectRevert(); // optional: you can calculate maxAfterInterest and use the error with selector
        castLendingProxy.borrow(address(tokenUSDT), excessiveAmount, address(tokenBTC), 30 days);
        vm.stopPrank();
    }

    // ========== repay TESTs ==========
    function test_repay_half() public {
        uint16 ltv = 5000; // 50%
        uint256 fundLiquidity = 1_000_000e18;
        uint256 fundCollateral = 1e18;

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
        LendingCoreV1.Loan memory loanBefore = castLendingProxy.getUserLoan(user1, address(tokenBTC));

        uint256 repayAmount = borrowAmount;

        vm.startPrank(user1);
        IERC20Metadata(address(tokenUSDT)).approve(address(lendingProxy), repayAmount);

        vm.expectEmit(true, true, true, true);
        emit LendingCoreV1.Repaid(user1, address(tokenBTC), repayAmount);

        castLendingProxy.repay(address(tokenBTC), repayAmount);
        vm.stopPrank();

        LendingCoreV1.Loan memory loanAfter = castLendingProxy.getUserLoan(user1, address(tokenBTC));
        assertEq(loanAfter.repaidAmount, loanBefore.repaidAmount + repayAmount);
    }

    function test_repay_full() public {
        uint16 ltv = 5000; // 50%
        uint256 fundLiquidity = 1_000_000e18;
        uint256 fundCollateral = 1e18;

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

        uint256 interest = castLendingProxy.getUserLoan(user1, address(tokenBTC)).interestAccrued;
        uint256 repayAmount = borrowAmount + interest;

        _fund(address(tokenUSDT), user1, repayAmount);

        vm.startPrank(user1);
        IERC20Metadata(address(tokenUSDT)).approve(address(lendingProxy), repayAmount);

        vm.expectEmit(true, true, true, true);
        emit LendingCoreV1.Repaid(user1, address(tokenBTC), repayAmount);

        castLendingProxy.repay(address(tokenBTC), repayAmount);
        vm.stopPrank();

        LendingCoreV1.Loan memory loanAfter = castLendingProxy.getUserLoan(user1, address(tokenBTC));

        assertEq(loanAfter.principal, 0);
        assertEq(loanAfter.interestAccrued, 0);
        assertEq(loanAfter.repaidAmount, 0);
        assertEq(loanAfter.totalLiquidated, 0);
        assertEq(loanAfter.borrowToken, address(0));
        assertEq(loanAfter.startTime, 0);
        assertEq(loanAfter.dueDate, 0);
        assertFalse(loanAfter.active);
    }

    function test_revert_repay_zeroCollateralToken() public {
        vm.startPrank(user1);
        vm.expectRevert(LendingCoreV1.LendingCore__InvalidAddress.selector);
        castLendingProxy.repay(address(0), 1e18);
        vm.stopPrank();
    }

    function test_revert_repay_zeroAmount() public {
        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));

        vm.startPrank(user1);
        vm.expectRevert(LendingCoreV1.LendingCore__ZeroAmountNotAllowed.selector);
        castLendingProxy.repay(address(tokenBTC), 0);
        vm.stopPrank();
    }

    function test_revert_repay_unsupportedCollateralToken() public {
        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        // note: no collateral token added

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(LendingCoreV1.LendingCore__UnsupportedToken.selector, address(tokenBTC)));
        castLendingProxy.repay(address(tokenBTC), 1e18);
        vm.stopPrank();
    }

    function test_revert_repay_loanInactive() public {
        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));

        vm.startPrank(user1);
        vm.expectRevert(LendingCoreV1.LendingCore__LoanIsInactive.selector);
        castLendingProxy.repay(address(tokenBTC), 1e18);
        vm.stopPrank();
    }

    function test_revert_repay_exceedsRemainingDebt() public {
        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _setLTV(address(tokenBTC), 5000);
        _setMaxBorrowDuration(730 days);
        _fund(address(tokenUSDT), liquidityProvider, 1_000_000e18);
        _fund(address(tokenBTC), user1, 1e18);
        _addLiquidity(address(tokenUSDT), 1_000_000e18);
        _approveAndDepositCollateral(user1, address(tokenBTC), 1e18);

        uint256 borrowAmount =
            castLendingProxy.getMaxBorrowBeforeInterest(user1, address(tokenUSDT), address(tokenBTC)) / 2;

        vm.startPrank(user1);
        castLendingProxy.borrow(address(tokenUSDT), borrowAmount, address(tokenBTC), 30 days);
        vm.stopPrank();

        _fund(address(tokenUSDT), user1, borrowAmount + 1e18);

        vm.startPrank(user1);
        IERC20Metadata(address(tokenUSDT)).approve(address(lendingProxy), borrowAmount + 1e18);

        uint256 remaining = castLendingProxy.getUserLoan(user1, address(tokenBTC)).principal
            + castLendingProxy.getUserLoan(user1, address(tokenBTC)).interestAccrued;

        vm.expectRevert(
            abi.encodeWithSelector(LendingCoreV1.LendingCore__AmountExceedsLimit.selector, remaining, remaining + 1)
        );
        castLendingProxy.repay(address(tokenBTC), remaining + 1);
        vm.stopPrank();
    }

    // ========== liquidate TESTs ==========
    function test_liquidate() public {
        // 1. Setup tokens, price-feeds, and protocol parameters
        uint16 ltv = 7000; // 70%
        uint16 liquidationPenalty = 500; // 5%

        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _setLTV(address(tokenBTC), ltv);
        _setMaxBorrowDuration(365 days);
        _setLiquidationPenalty(address(tokenBTC), liquidationPenalty);

        // 2. User1 deposits 1 BTC as collateral ($100,000)
        uint256 depositAmount = 1e18;
        _fund(address(tokenBTC), user1, depositAmount);
        _approveAndDepositCollateral(user1, address(tokenBTC), depositAmount);

        // 3. LiquidityProvider adds 100,000 USDT to the pool
        uint256 lpAmount = 100_000e18;
        _fund(address(tokenUSDT), liquidityProvider, lpAmount);
        _addLiquidity(address(tokenUSDT), lpAmount);

        // 4. User1 borrows under LTV limit
        uint16 BPS_DENOMINATOR = 10000;

        vm.startPrank(user1);
        uint40 borrowDuration = 30 days;
        uint256 borrowAmount = Math.mulDiv(
            castLendingProxy.getMaxBorrowBeforeInterest(user1, address(tokenUSDT), address(tokenBTC)),
            BPS_DENOMINATOR,
            BPS_DENOMINATOR + castLendingProxy.getCurrentInterestRateBPS(address(tokenUSDT), borrowDuration)
        );

        castLendingProxy.borrow(address(tokenUSDT), borrowAmount, address(tokenBTC), borrowDuration);
        vm.stopPrank();

        // 5. Simulate price crash: BTC drops 25% to $75.000
        vm.startPrank(oracleHandler);
        tellorOracle.submitValue(queryIdBTC, abi.encode(priceBTC - (priceBTC / 5)), 0, queryDataBTC);
        vm.warp(block.timestamp + DISPUTE_BUFFER + 1);
        vm.stopPrank();

        // 6. Liquidator performs liquidation
        (uint256 principal, uint256 interestAccrued, uint256 repaid,, address borrowToken,,,) =
            castLendingProxy.s_userLoans(user1, address(tokenBTC));
        vm.startPrank(liquidator);

        // same calculations as in core contract
        uint256 userRemainingDebt = principal + interestAccrued - repaid;
        uint256 userDebtUsd = priceOracle.getValue(borrowToken, userRemainingDebt);

        uint256 repayAmountUsd;
        uint256 repayTokenAmount;

        uint256 denominator = Math.mulDiv(ltv, BPS_DENOMINATOR + liquidationPenalty, BPS_DENOMINATOR);
        repayAmountUsd = Math.mulDiv(userDebtUsd, BPS_DENOMINATOR, denominator);
        if (repayAmountUsd > userDebtUsd) {
            repayAmountUsd = userDebtUsd;
        }
        repayTokenAmount = _usdToTokenAmount(repayAmountUsd, borrowToken);

        uint256 expectedSeizeAmount;

        uint256 penaltyUsd = Math.mulDiv(repayAmountUsd, liquidationPenalty, BPS_DENOMINATOR);
        uint256 totalSeizeUsd = repayAmountUsd + penaltyUsd;

        expectedSeizeAmount = _usdToTokenAmount(totalSeizeUsd, address(tokenBTC));

        vm.expectEmit(true, true, false, true);
        emit LendingCoreV1.Liquidated(user1, address(tokenBTC), expectedSeizeAmount);

        castLendingProxy.liquidate(user1, address(tokenBTC));
        vm.stopPrank();

        LendingCoreV1.Loan memory loanAfter = castLendingProxy.getUserLoan(user1, address(tokenBTC));

        // 7. Post-conditions
        assertGt(loanAfter.repaidAmount, 0, "should have repaid some USDT");
        assertEq(loanAfter.totalLiquidated, expectedSeizeAmount, "should have seized some BTC");
        assertLt(
            castCollateralManagerProxy.getDepositedCollateral(user1, address(tokenBTC)),
            depositAmount,
            "collateral should be reduced"
        );
    }

    function test_revert_liquidate_zeroAddressParams() public {
        vm.startPrank(liquidator);
        vm.expectRevert(LendingCoreV1.LendingCore__InvalidAddress.selector);
        castLendingProxy.liquidate(address(0), address(tokenBTC));

        vm.expectRevert(LendingCoreV1.LendingCore__InvalidAddress.selector);
        castLendingProxy.liquidate(user1, address(0));
        vm.stopPrank();
    }

    function test_revert_liquidate_unsupportedCollateral() public {
        _setupTokensAndPriceFeeds(); // tokenBTC added, but not marked as collateral token
        vm.startPrank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(LendingCoreV1.LendingCore__UnsupportedToken.selector, address(tokenBTC)));
        castLendingProxy.liquidate(user1, address(tokenBTC));
        vm.stopPrank();
    }

    function test_revert_liquidate_notLiquidateable_healthOk() public {
        // Setup a healthy loan (e.g., collateral value is still high)
        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _setLTV(address(tokenBTC), 8000);
        _setMaxBorrowDuration(730 days);
        _fund(address(tokenUSDT), liquidityProvider, 1_000_000e18);
        _addLiquidity(address(tokenUSDT), 1_000_000e18);
        _fund(address(tokenBTC), user1, 1e18);
        _approveAndDepositCollateral(user1, address(tokenBTC), 1e18);

        uint256 borrowAmount =
            castLendingProxy.getMaxBorrowBeforeInterest(user1, address(tokenUSDT), address(tokenBTC)) / 2;

        vm.startPrank(user1);
        castLendingProxy.borrow(address(tokenUSDT), borrowAmount, address(tokenBTC), 30 days);
        vm.stopPrank();

        // Health factor still above 1 and loan not expired
        vm.startPrank(liquidator);
        vm.expectRevert(LendingCoreV1.LendingCore__NotLiquidateable.selector);
        castLendingProxy.liquidate(user1, address(tokenBTC));
        vm.stopPrank();
    }

    function test_revert_liquidate_loanInactive() public {
        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));

        // manually store a loan with `active = false`
        bytes32 slot = keccak256(abi.encode(user1, keccak256(abi.encode(address(tokenBTC), uint256(3)))));
        // set .active to false (last slot var)
        vm.store(address(lendingProxy), bytes32(uint256(slot) + 6), bytes32(uint256(0))); // Loan.active = false

        vm.startPrank(liquidator);
        vm.expectRevert(LendingCoreV1.LendingCore__LoanIsInactive.selector);
        castLendingProxy.liquidate(user1, address(tokenBTC));
        vm.stopPrank();
    }

    // ========== addLiquidity TESTs ==========
    function test_addLiquidity_half() public {
        uint256 fundLiquidity = 1_000_000e18; // 1.000.000 USDT

        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _fund(address(tokenUSDT), liquidityProvider, fundLiquidity);

        uint256 addAmount = fundLiquidity / 2;
        _addLiquidity(address(tokenUSDT), addAmount);

        uint256 balance = IERC20Metadata(address(tokenUSDT)).balanceOf(address(lendingProxy));
        assertEq(balance, addAmount);
    }

    function test_addLiquidity_full() public {
        uint256 fundLiquidity = 1_000_000e18; // 1.000.000 USDT

        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _fund(address(tokenUSDT), liquidityProvider, fundLiquidity);

        uint256 addAmount = fundLiquidity;
        _addLiquidity(address(tokenUSDT), addAmount);

        uint256 balance = tokenUSDT.balanceOf(address(lendingProxy));
        assertEq(balance, addAmount);
    }

    // ========== removeLiquidity TESTs ==========
    function test_removeLiquidity_half() public {
        uint256 fundLiquidity = 1_000_000e18; // 1.000.000 USDT

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
        uint256 fundLiquidity = 1_000_000e18; // 1.000.000 USDT

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

    // ========== addBorrowToken TESTs ==========
    function test_addBorrowToken() public {
        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));

        bool isSupported = castLendingProxy.s_isBorrowTokenSupported(address(tokenUSDT));
        address addedToken = castLendingProxy.s_borrowTokens(0);
        assertEq(isSupported, true);
        assertEq(addedToken, address(tokenUSDT));
    }

    // ========== removeBorrowToken TESTs ==========
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

    // ========== addCollateralToken TESTs ==========
    function test_addCollateralToken() public {
        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));

        bool isSupported = castCollateralManagerProxy.s_isCollateralTokenSupported(address(tokenBTC));
        address addedToken = castCollateralManagerProxy.s_collateralTokens(0);
        assertEq(isSupported, true);
        assertEq(addedToken, address(tokenBTC));
    }

    // ========== removeCollateralToken TESTs ==========
    function test_removeCollateralToken() public {
        _setupTokensAndPriceFeeds();
        test_addCollateralToken();

        vm.startPrank(tokenManager);
        castLendingProxy.removeCollateralToken(address(tokenBTC));
        vm.stopPrank();

        bool isSupported = castCollateralManagerProxy.s_isCollateralTokenSupported(address(tokenBTC));
        assertEq(isSupported, false);
    }

    // ========== setLTV TESTs ==========
    function test_setLTV() public {
        uint16 ltvRatio = 5000; // 50%

        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _setLTV(address(tokenBTC), ltvRatio);

        uint16 ltv = castLendingProxy.s_ltvBPS(address(tokenBTC));
        assertEq(ltv, ltvRatio);
    }

    // ========== setLiquidationPenalty TESTs ==========
    function test_setLiquidationPenalty() public {
        uint16 liquidationPenalty = 1000; // 10%
        _setLiquidationPenalty(address(tokenBTC), liquidationPenalty);

        uint16 penalty = castLendingProxy.s_liquidationPenaltyBPS(address(tokenBTC));
        assertEq(penalty, liquidationPenalty);
    }

    // ========== setMaxBorrowDuration TESTs ==========
    function test_setMaxBorrowDuration() public {
        uint40 durationAmount = 365 days;
        _setMaxBorrowDuration(durationAmount);

        uint64 duration = castLendingProxy.s_maxBorrowDuration();
        assertEq(duration, durationAmount);
    }

    // ========== setGracePeriod TESTs ==========
    function test_setGracePeriod() public {
        uint40 periodAmount = 7 days;
        _setGracePeriod(periodAmount);

        uint64 period = castLendingProxy.s_gracePeriod();
        assertEq(period, periodAmount);
    }

    // ========== pause TESTs ==========
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

    // ========== VIEW FUNCTION TESTS =========
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
}
