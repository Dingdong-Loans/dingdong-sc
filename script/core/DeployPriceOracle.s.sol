// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {PriceOracle} from "../../src/core/PriceOracle.sol";

contract DeployPriceOracle is Script {
    function run() external {
        address initialOwner = vm.envAddress("CORE_PROXY");
        address payable tellorOracle = payable(vm.envAddress("TELLOR_ORACLE"));

        vm.startBroadcast();
        PriceOracle irm = new PriceOracle(initialOwner, tellorOracle);
        vm.stopBroadcast();

        console.log("PriceOracle deployed at:", address(irm));
    }
}
