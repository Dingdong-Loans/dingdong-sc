// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {InterestRateModel} from "../../src/core/InterestRateModel.sol";

contract DeployInterestRateModel is Script {
    function run() external {
        address initialOwner = vm.envAddress("CORE_PROXY");

        vm.startBroadcast();
        InterestRateModel irm = new InterestRateModel(initialOwner);
        vm.stopBroadcast();

        console.log("InterestRateModel deployed at:", address(irm));
    }
}
