// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {LendingCoreV1} from "../../src/core/LendingCoreV1.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployLendingCoreV1 is Script {
    function run() external {
        address defaultAdmin;
        address[6] memory roles;

        defaultAdmin = vm.envAddress("DEFAULT_ADMIN");
        roles[0] = vm.envAddress("PAUSER_ROLE");
        roles[1] = vm.envAddress("UPGRADER_ROLE");
        roles[2] = vm.envAddress("PARAMETER_MANAGER_ROLE");
        roles[3] = vm.envAddress("TOKEN_MANAGER_ROLE");
        roles[4] = vm.envAddress("LIQUIDITY_PROVIDER_ROLE");
        roles[5] = vm.envAddress("LIQUIDATOR_ROLE");

        vm.startBroadcast();
        // 1. Deploy implementation
        LendingCoreV1 coreImpl = new LendingCoreV1();
        // 2. Encode initialize call
        bytes memory initData = abi.encodeWithSelector(coreImpl.initialize.selector, defaultAdmin, roles);
        // 3. Deploy Proxy with implementation and initData
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImpl), initData);
        vm.stopBroadcast();

        console.log("LendingCore Proxy deployed at:", address(proxy));
        console.log("Implementation at:", address(coreImpl));
    }
}
