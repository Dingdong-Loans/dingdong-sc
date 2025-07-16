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

contract LendingCoreV1Fuzz is Test {
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

    uint256 private constant BPS_DENOMINATOR = 10000;

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

    // ========== depositCollateral Fuzz ==========
    function test_fuzz_depositCollateral(address user, uint256 amount) public {
        vm.assume(user != address(0) && user != address(this));
        vm.assume(amount > 0);

        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));

        _fund(address(tokenBTC), user, amount);

        vm.startPrank(user);
        IERC20Metadata(address(tokenBTC)).approve(address(lendingProxy), amount);
        castLendingProxy.depositCollateral(address(tokenBTC), amount);
        vm.stopPrank();

        assertEq(amount, castCollateralManagerProxy.getDepositedCollateral(user, address(tokenBTC)));
    }

    function test_fuzz_withdrawCollateral(uint256 amount) public {
        vm.assume(amount > 0);

        _setupTokensAndPriceFeeds();
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));

        _fund(address(tokenBTC), user1, amount);

        vm.startPrank(user1);
        // deposit
        IERC20Metadata(address(tokenBTC)).approve(address(lendingProxy), amount);
        castLendingProxy.depositCollateral(address(tokenBTC), amount);

        // withdraw
        castLendingProxy.withdrawCollateral(address(tokenBTC), amount);
        vm.stopPrank();

        assertEq(castCollateralManagerProxy.getDepositedCollateral(user1, address(tokenBTC)), 0);
    }

    function test_fuzz_borrow(uint256 amount, uint40 duration) public {
        uint40 maxBorrowDuration = 730 days;
        uint16 ltv = 5000;
        uint256 fundLiquidity = 1_000_000e18;
        uint256 fundCollateral = 1e18;

        uint256 minBorrowAmount = 1e18; // 1 USDT minimum
        uint40 minBorrowDuration = 1 days;

        _setupTokensAndPriceFeeds();
        _addBorrowToken(address(tokenUSDT), address(pricefeedUSDT));
        _addCollateralToken(address(tokenBTC), address(pricefeedBTC));
        _setLTV(address(tokenBTC), ltv);
        _setMaxBorrowAmount(address(tokenUSDT), fundLiquidity);
        _setMinBorrowAmount(address(tokenUSDT), minBorrowAmount);
        _setMaxBorrowDuration(maxBorrowDuration);
        _setMinBorrowDuration(minBorrowDuration);
        _fund(address(tokenBTC), user1, fundCollateral);
        _fund(address(tokenUSDT), liquidityProvider, fundLiquidity);
        _addLiquidity(address(tokenUSDT), fundLiquidity);
        _approveAndDepositCollateral(user1, address(tokenBTC), fundCollateral);

        uint256 maxBorrowAmount = Math.mulDiv(
            castLendingProxy.getMaxBorrowBeforeInterest(user1, address(tokenUSDT), address(tokenBTC)),
            BPS_DENOMINATOR,
            BPS_DENOMINATOR + castLendingProxy.getCurrentInterestRateBPS(address(tokenUSDT), duration)
        );

        vm.assume(amount >= minBorrowAmount && amount <= maxBorrowAmount);
        vm.assume(duration <= maxBorrowDuration && duration >= minBorrowDuration);

        vm.startPrank(user1);
        castLendingProxy.borrow(address(tokenUSDT), amount, address(tokenBTC), duration);
        vm.stopPrank();

        LendingCoreV1.Loan memory loan = castLendingProxy.getUserLoan(user1, address(tokenBTC));
        assertEq(loan.borrowToken, address(tokenUSDT));
        assertTrue(loan.principal + loan.interestAccrued > amount);
        assertTrue(loan.active);
    }
}
