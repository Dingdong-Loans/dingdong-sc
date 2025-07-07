// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {LendingCore} from "../../src/core/LendingCoreV1.sol";
import {CollateralManager} from "../../src/core/CollateralManager.sol";
import {InterestRateModel} from "../../src/core/InterestRateModel.sol";
import {PriceOracle} from "../../src/core/PriceOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

contract LendingCoreV1Test is Test {
    ERC1967Proxy public proxy;
    LendingCore public lending;

    CollateralManager public collateralManager;
    InterestRateModel public interestRateModel;
    PriceOracle public priceOracle;

    MockERC20 public debtToken1;
    MockERC20 public debtToken2;
    MockERC20 public collateralToken1;
    MockERC20 public collateralToken2;

    address public admin = makeAddr("ADMIN");
    address public pauser = makeAddr("PAUSER");
    address public upgrader = makeAddr("UPGRADER");
    address public parameterManager = makeAddr("PARAMETER_MANAGER");
    address public liquidityProvider = makeAddr("LIQUIDITY_PROVIDER");
    address public tokenManager = makeAddr("TOKEN_MANAGER");
    address public liquidator = makeAddr("LIQUIDATOR");

    address public user1 = makeAddr("USER1");

    function setUp() public {
        debtToken1 = collateralToken1 = new MockERC20("Regular ERC20", "ERC20", 18);
        debtToken2 = collateralToken2 = new MockERC20("Modified Decimals ERC20", "MERC20", 8);

        bytes memory data = abi.encodeWithSelector(
            LendingCore.initialize.selector,
            admin,
            [pauser, upgrader, parameterManager, tokenManager, liquidityProvider, liquidator]
        );

        lending = new LendingCore();
        proxy = new ERC1967Proxy(address(lending), data);
    }

    function test_checkInitialization() public view {
        // Check that the proxy points to the correct implementation
        // assertEq(proxy.getImplementation(), address(lending));

        // Check that roles are properly assigned
        assertTrue(LendingCore(address(proxy)).hasRole(LendingCore(address(proxy)).DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(LendingCore(address(proxy)).hasRole(LendingCore(address(proxy)).PAUSER_ROLE(), pauser));
        assertTrue(LendingCore(address(proxy)).hasRole(LendingCore(address(proxy)).UPGRADER_ROLE(), upgrader));
        assertTrue(
            LendingCore(address(proxy)).hasRole(LendingCore(address(proxy)).PARAMETER_MANAGER_ROLE(), parameterManager)
        );
        assertTrue(LendingCore(address(proxy)).hasRole(LendingCore(address(proxy)).TOKEN_MANAGER_ROLE(), tokenManager));
        assertTrue(
            LendingCore(address(proxy)).hasRole(
                LendingCore(address(proxy)).LIQUIDITY_PROVIDER_ROLE(), liquidityProvider
            )
        );
        assertTrue(LendingCore(address(proxy)).hasRole(LendingCore(address(proxy)).LIQUIDATOR_ROLE(), liquidator));

        // Check that the contract is not paused after initialization
        assertFalse(LendingCore(address(proxy)).paused());

        // Check that the BPS denominator is set correctly
        assertEq(LendingCore(address(proxy)).BPS_DENOMINATOR(), 10000);

        // Check that the max borrow duration is set to 2 years (730 days)
        assertEq(LendingCore(address(proxy)).s_maxBorrowDuration(), 0);

        // Check that the grace period is set to 1 hour
        assertEq(LendingCore(address(proxy)).s_gracePeriod(), 0);

        // Check that modules are not set yet
        assertEq(address(LendingCore(address(proxy)).s_collateralManager()), address(0));
        assertEq(address(LendingCore(address(proxy)).s_interestRateModel()), address(0));
        assertEq(address(LendingCore(address(proxy)).s_priceOracle()), address(0));

        // Check that debt tokens and collateral tokens arrays are empty
        // assertEq(LendingCore(address(proxy)).s_debtTokens().length, 0);
        // assertEq(LendingCore(address(proxy)).s_collateralTokens().length, 0);
    }
}
