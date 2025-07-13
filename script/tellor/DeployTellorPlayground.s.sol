// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {TellorPlayground} from "@tellor/contracts/TellorPlayground.sol";

contract DeployTellorPlayground is Script {
    function run() external {
        vm.startBroadcast();
        TellorPlayground tellorOracle = new TellorPlayground();
        vm.stopBroadcast();

        console.log("TellorPlayground deployed at:", address(tellorOracle));
    }
}
