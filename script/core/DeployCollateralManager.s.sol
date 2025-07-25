// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {CollateralManager} from "../../src/core/CollateralManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployCollateralManager is Script {
    function run() external {
        address initialOwner = vm.envAddress("CORE_PROXY");

        vm.startBroadcast();
        // 1. Deploy implementation
        CollateralManager impl = new CollateralManager();
        // 2. Encode initializer call
        bytes memory initData = abi.encodeWithSelector(impl.initialize.selector, initialOwner);
        // 3. Deploy proxy with implementation and init data
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vm.stopBroadcast();

        console.log("CollateralManager Proxy deployed at:", address(proxy));
        console.log("Implementation at:", address(impl));
    }
}
