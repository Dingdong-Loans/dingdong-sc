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

    modifier tokenReady() {
        vm.startPrank(tokenHandler);
        tokenUSDT = tokenBTC = new MockERC20("Regular ERC20", "ERC20", 18);
        tokenIDRX = tokenETH = new MockERC20("Modified Decimals ERC20", "MERC20", 8);
        vm.stopPrank();
        _;
    }

    modifier pricefeedReady() {
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
        vm.stopPrank();
        _;
    }

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
        priceOracle = new PriceOracle(admin);
        // initialize InterestRateModel
        interestRateModel = new InterestRateModel(admin);
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

    function _fund(address _token, address _account, uint256 _value) internal {
        vm.startPrank(tokenHandler);
        MockERC20(_token).mint(_account, _value);
        vm.stopPrank();
    }

    function test_checkInitialization() public view {
        // Check that the lendingProxy points to the correct implementation
        // assertEq(lendingProxy.getImplementation(), address(lending));

        // Check that roles are properly assigned
        assertTrue(
            LendingCore(address(lendingProxy)).hasRole(LendingCore(address(lendingProxy)).DEFAULT_ADMIN_ROLE(), admin)
        );
        assertTrue(LendingCore(address(lendingProxy)).hasRole(LendingCore(address(lendingProxy)).PAUSER_ROLE(), pauser));
        assertTrue(
            LendingCore(address(lendingProxy)).hasRole(LendingCore(address(lendingProxy)).UPGRADER_ROLE(), upgrader)
        );
        assertTrue(
            LendingCore(address(lendingProxy)).hasRole(
                LendingCore(address(lendingProxy)).PARAMETER_MANAGER_ROLE(), parameterManager
            )
        );
        assertTrue(
            LendingCore(address(lendingProxy)).hasRole(
                LendingCore(address(lendingProxy)).TOKEN_MANAGER_ROLE(), tokenManager
            )
        );
        assertTrue(
            LendingCore(address(lendingProxy)).hasRole(
                LendingCore(address(lendingProxy)).LIQUIDITY_PROVIDER_ROLE(), liquidityProvider
            )
        );
        assertTrue(
            LendingCore(address(lendingProxy)).hasRole(LendingCore(address(lendingProxy)).LIQUIDATOR_ROLE(), liquidator)
        );

        // Check that the contract is not paused after initialization
        assertFalse(LendingCore(address(lendingProxy)).paused());

        // Check that the BPS denominator is set correctly
        assertEq(LendingCore(address(lendingProxy)).BPS_DENOMINATOR(), 10000);

        // Check that the max borrow duration is set to 2 years (730 days)
        assertEq(LendingCore(address(lendingProxy)).s_maxBorrowDuration(), 0);

        // Check that the grace period is set to 1 hour
        assertEq(LendingCore(address(lendingProxy)).s_gracePeriod(), 0);

        // Check that modules are not set yet
        assertEq(address(LendingCore(address(lendingProxy)).s_collateralManager()), address(collateralManagerProxy));
        assertEq(address(LendingCore(address(lendingProxy)).s_interestRateModel()), address(interestRateModel));
        assertEq(address(LendingCore(address(lendingProxy)).s_priceOracle()), address(priceOracle));
    }
}
