// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
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

        /// @dev mock price value with 8 decimal
        uint256 priceUSDT = 1e8;
        uint256 priceIDRX = 6042;
        uint256 priceBTC = 100000e8;
        uint256 priceETH = 2500e8;

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

    function _addDebtToken(address token, address priceFeed) internal {
        vm.startPrank(tokenManager);
        castLendingProxy.addDebtToken(token, priceFeed);
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
        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _fund(address(tokenBTC), user1, 1e18);

        uint256 amount = 0.5e18;
        _approveAndDepositCollateral(user1, address(tokenBTC), amount);

        uint256 depositedAmount = castCollateralManagerProxy.getDepositedCollateral(user1, address(tokenBTC));
        assertEq(depositedAmount, amount);
    }

    function test_withdrawCollateral() public {
        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _fund(address(tokenBTC), user1, 1e18);
        _approveAndDepositCollateral(user1, address(tokenBTC), 0.5e18);

        uint256 withdrawAmount = 0.2e18;
        vm.startPrank(user1);
        castLendingProxy.withdrawCollateral(address(tokenBTC), withdrawAmount);
        vm.stopPrank();

        uint256 remainingAmount = castCollateralManagerProxy.getDepositedCollateral(user1, address(tokenBTC));
        assertEq(remainingAmount, 0.3e18);
    }

    function test_borrow() public {
        uint16 ltv = 5000; // 50%
        uint256 fundLiquidity = 1000e18;
        uint256 fundCollateral = 1e18;

        _setupTokensAndPriceFeeds();
        _addDebtToken(address(tokenUSDT), address(pricefeedUSDT));
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _setLTV(address(tokenBTC), ltv);
        _fund(address(tokenBTC), user1, fundCollateral);
        _fund(address(tokenUSDT), liquidityProvider, fundLiquidity);
        _addLiquidity(address(tokenUSDT), fundLiquidity);
        _approveAndDepositCollateral(user1, address(tokenBTC), fundCollateral);

        uint256 borrowAmount = 0.4e18;
        vm.startPrank(user1);
        castLendingProxy.borrow(address(tokenUSDT), borrowAmount, address(tokenBTC), 30 days);
        vm.stopPrank();

        LendingCore.Loan memory loan = castLendingProxy.getUserLoan(user1, address(tokenBTC));
        assertEq(loan.borrowToken, address(tokenUSDT));
        assertEq(loan.borrowAmount > borrowAmount, true);
        assertEq(loan.active, true);
    }

    function test_repay() public {
        _setupTokensAndPriceFeeds();
        _addDebtToken(address(tokenUSDT), address(pricefeedUSDT));
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _setLTV(address(tokenBTC), 5000);
        _fund(address(tokenBTC), user1, 1e18);
        _fund(address(tokenUSDT), liquidityProvider, 1000e18);
        _addLiquidity(address(tokenUSDT), 1000e18);
        _approveAndDepositCollateral(user1, address(tokenBTC), 1e18);

        vm.startPrank(user1);
        castLendingProxy.borrow(address(tokenUSDT), 0.4e18, address(tokenBTC), 30 days);
        vm.stopPrank();

        _fund(address(tokenUSDT), user1, 1000e18);
        LendingCore.Loan memory loanBefore = castLendingProxy.getUserLoan(user1, address(tokenBTC));

        uint256 repayAmount = 0.2e18;
        vm.startPrank(user1);
        IERC20Metadata(address(tokenUSDT)).approve(address(lendingProxy), repayAmount);
        castLendingProxy.repay(address(tokenBTC), repayAmount);
        vm.stopPrank();

        LendingCore.Loan memory loanAfter = castLendingProxy.getUserLoan(user1, address(tokenBTC));
        assertEq(loanAfter.repaidAmount, loanBefore.repaidAmount + repayAmount);
    }

    function test_addLiquidity() public {
        _setupTokensAndPriceFeeds();
        _addDebtToken(address(tokenUSDT), address(pricefeedUSDT));
        _fund(address(tokenUSDT), liquidityProvider, 1000e18);

        uint256 amount = 500e18;
        _addLiquidity(address(tokenUSDT), amount);

        uint256 balance = IERC20Metadata(address(tokenUSDT)).balanceOf(address(lendingProxy));
        assertEq(balance, amount);
    }

    function test_removeLiquidity() public {
        uint256 amount = 200e18;

        _setupTokensAndPriceFeeds();
        _fund(address(tokenUSDT), liquidityProvider, amount);
        _addLiquidity(address(tokenUSDT), amount);

        vm.startPrank(liquidityProvider);
        castLendingProxy.removeLiquidity(address(tokenUSDT), amount);
        vm.stopPrank();

        uint256 providerBalance = IERC20Metadata(address(tokenUSDT)).balanceOf(liquidityProvider);
        assertEq(providerBalance, amount);
    }

    function test_addDebtToken() public {
        _setupTokensAndPriceFeeds();
        _addDebtToken(address(tokenUSDT), address(pricefeedUSDT));

        bool isSupported = castLendingProxy.s_isDebtTokenSupported(address(tokenUSDT));
        assertEq(isSupported, true);
    }

    function test_removeDebtToken() public {
        _setupTokensAndPriceFeeds();
        test_addDebtToken();

        vm.startPrank(tokenManager);
        castLendingProxy.removeDebtToken(address(tokenUSDT));
        vm.stopPrank();

        bool isSupported = castLendingProxy.s_isDebtTokenSupported(address(tokenUSDT));
        assertEq(isSupported, false);
    }

    function test_addCollateralToken() public {
        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));

        bool isSupported = castCollateralManagerProxy.s_isCollateralTokenSupported(address(tokenBTC));
        assertEq(isSupported, true);
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
        _setLTV(address(tokenBTC), 5000);

        uint16 ltv = castLendingProxy.s_ltvBPS(address(tokenBTC));
        assertEq(ltv, 5000);
    }

    function test_setLiquidationPenalty() public {
        _setLiquidationPenalty(address(tokenBTC), 1000);

        uint16 penalty = castLendingProxy.s_liquidationPenaltyBPS(address(tokenBTC));
        assertEq(penalty, 1000);
    }

    function test_setMaxBorrowDuration() public {
        uint64 duration = 365 days;
        vm.startPrank(parameterManager);
        castLendingProxy.setMaxBorrowDuration(duration);
        vm.stopPrank();

        uint64 setDuration = castLendingProxy.s_maxBorrowDuration();
        assertEq(setDuration, duration);
    }

    function test_setGracePeriod() public {
        uint64 period = 7 days;
        vm.startPrank(parameterManager);
        castLendingProxy.setGracePeriod(period);
        vm.stopPrank();

        uint64 setPeriod = castLendingProxy.s_gracePeriod();
        assertEq(setPeriod, period);
    }

    function test_pauseUnpause() public {
        vm.startPrank(pauser);
        castLendingProxy.pause();
        vm.stopPrank();

        assertTrue(castLendingProxy.paused());

        vm.startPrank(pauser);
        castLendingProxy.unpause();
        vm.stopPrank();

        assertFalse(castLendingProxy.paused());
    }

    function test_getAvailableSupply() public {
        _setupTokensAndPriceFeeds();
        _addDebtToken(address(tokenUSDT), address(pricefeedUSDT));
        _fund(address(tokenUSDT), liquidityProvider, 1000e18);
        _addLiquidity(address(tokenUSDT), 500e18);

        uint256 availableSupply = castLendingProxy.getAvailableSupply(address(tokenUSDT));
        assertEq(availableSupply, 500e18);
    }

    function test_getTotalSupply() public {
        _setupTokensAndPriceFeeds();
        _addDebtToken(address(tokenUSDT), address(pricefeedUSDT));
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _setLTV(address(tokenBTC), 5000);
        _fund(address(tokenBTC), user1, 1e18);
        _fund(address(tokenUSDT), liquidityProvider, 1000e18);
        _addLiquidity(address(tokenUSDT), 500e18);
        _approveAndDepositCollateral(user1, address(tokenBTC), 1e18);

        vm.startPrank(user1);
        castLendingProxy.borrow(address(tokenUSDT), 100e18, address(tokenBTC), 30 days);
        vm.stopPrank();

        uint256 totalSupply = castLendingProxy.getTotalSupply(address(tokenUSDT));
        assertEq(totalSupply, 500e18);
    }

    function test_getUtilizationBPS() public {
        _setupTokensAndPriceFeeds();
        _addDebtToken(address(tokenUSDT), address(pricefeedUSDT));
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _setLTV(address(tokenBTC), 5000);
        _fund(address(tokenBTC), user1, 1e18);
        _fund(address(tokenUSDT), liquidityProvider, 1000e18);
        _addLiquidity(address(tokenUSDT), 500e18);
        _approveAndDepositCollateral(user1, address(tokenBTC), 1e18);

        vm.startPrank(user1);
        castLendingProxy.borrow(address(tokenUSDT), 100e18, address(tokenBTC), 30 days);
        vm.stopPrank();

        uint256 utilization = castLendingProxy.getUtilizationBPS(address(tokenUSDT));
        assertEq(utilization, 2000);
    }
}
