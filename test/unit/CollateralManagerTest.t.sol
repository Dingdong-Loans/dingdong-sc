// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {CollateralManager} from "../../src/core/CollateralManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract CollateralManagerTest is Test {
    ERC1967Proxy proxy;
    CollateralManager manager;
    CollateralManager castManagerProxy;

    MockERC20 mockToken;

    address owner = makeAddr("OWNER");

    function setUp() public {
        manager = new CollateralManager();

        bytes memory data = abi.encodeWithSelector(CollateralManager.initialize.selector, owner);
        proxy = new ERC1967Proxy(address(manager), data);
        castManagerProxy = CollateralManager(address(proxy));

        mockToken = new MockERC20("Mock Token", "MTK", 18);
    }

    function test_initialization() public view {
        assertEq(castManagerProxy.owner(), owner, "Owner should be initialized correctly");
    }

    function test_deposit() public {
        uint256 amount = 1000;

        vm.startPrank(owner);
        castManagerProxy.deposit(owner, address(mockToken), amount);

        assertEq(
            castManagerProxy.s_collateralBalance(owner, address(mockToken)),
            amount,
            "User balance should be updated after deposit"
        );
    }

    function test_withdraw_half() public {
        uint256 depositAmount = 1000;
        uint256 withdrawAmount = 500;

        vm.startPrank(owner);
        castManagerProxy.deposit(owner, address(mockToken), depositAmount);
        castManagerProxy.withdraw(owner, address(mockToken), withdrawAmount);

        assertEq(
            castManagerProxy.s_collateralBalance(owner, address(mockToken)),
            depositAmount - withdrawAmount,
            "User balance should be updated after withdrawal"
        );
    }

    function test_withdraw_full() public {
        uint256 depositAmount = 1000;

        vm.startPrank(owner);
        castManagerProxy.deposit(owner, address(mockToken), depositAmount);
        castManagerProxy.withdraw(owner, address(mockToken), depositAmount);
        vm.stopPrank();

        uint256 userBalance = castManagerProxy.s_collateralBalance(owner, address(mockToken));
        assertEq(userBalance, depositAmount - depositAmount, "User balance should be updated after withdrawal");
    }

    function test_addCollateralToken() public {
        vm.startPrank(owner);
        castManagerProxy.addCollateralToken(address(mockToken));
        vm.stopPrank();

        assertTrue(
            castManagerProxy.s_isCollateralTokenSupported(address(mockToken)), "Collateral token should be added"
        );
        assertEq(castManagerProxy.s_collateralTokens(0), address(mockToken), "Collateral token should be in the list");
    }

    function test_removeCollateralToken() public {
        vm.startPrank(owner);
        castManagerProxy.addCollateralToken(address(mockToken));
        castManagerProxy.removeCollateralToken(address(mockToken));
        vm.stopPrank();

        assertFalse(
            castManagerProxy.s_isCollateralTokenSupported(address(mockToken)), "Collateral token should be removed"
        );
    }

    function test_getDepositedCollateral() public {
        uint256 amount = 1000;

        vm.startPrank(owner);
        castManagerProxy.deposit(owner, address(mockToken), amount);
        vm.stopPrank();

        uint256 depositedAmount = castManagerProxy.getDepositedCollateral(owner, address(mockToken));
        assertEq(depositedAmount, amount, "Should return the correct deposited collateral amount");
    }
}
