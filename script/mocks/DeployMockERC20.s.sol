// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "../../test/mocks/MockERC20.sol";

contract DeployMockERC20Script is Script {
    function run() external {
        string memory name = vm.envString("TOKEN_NAME");
        string memory symbol = vm.envString("TOKEN_SYMBOL");
        uint8 decimals = uint8(vm.envUint("TOKEN_DECIMALS"));

        vm.startBroadcast();

        MockERC20 token = new MockERC20(name, symbol, decimals);

        console.log("MockERC20 deployed at:", address(token));
        console.log("Name:", token.name());
        console.log("Symbol:", token.symbol());
        console.log("Decimals:", token.decimals());

        vm.stopBroadcast();
    }
}
