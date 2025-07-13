// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {TellorUser} from "../../src/tellor/TellorUser.sol";

contract DeployTellorUser is Script {
    function run() external {
        address payable tellorOracle = payable(vm.envAddress("TELLOR_ORACLE"));
        string memory base = vm.envString("BASE_ASSET");
        string memory quote = vm.envString("QUOTE_ASSET");

        vm.startBroadcast();
        TellorUser oracle = new TellorUser(tellorOracle, base, quote);
        vm.stopBroadcast();

        console.log("TellorUser deployed at:", address(oracle));
        console.log("Pair: ", base, "/", quote);
    }
}
