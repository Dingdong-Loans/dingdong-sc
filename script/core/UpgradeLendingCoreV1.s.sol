// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {LendingCoreV1} from "../../src/core/LendingCoreV1.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract UpgradeLendingCoreV1 is Script {
    function run() external {
        vm.startBroadcast();
        // Current proxy
        address proxy = vm.envAddress("CORE_PROXY");
        // 1. Deploy new implementation
        LendingCoreV1 coreImpl = new LendingCoreV1();

        LendingCoreV1(proxy).upgradeToAndCall(address(coreImpl), "");
        vm.stopBroadcast();

        console.log("Implementation at:", address(coreImpl));
    }
}
