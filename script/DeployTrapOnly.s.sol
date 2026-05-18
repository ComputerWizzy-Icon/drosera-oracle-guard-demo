// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {OracleManipulationTrap} from "../src/OracleManipulationTrap.sol";

contract DeployTrapOnly is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        OracleManipulationTrap trap = new OracleManipulationTrap();
        vm.stopBroadcast();

        console.log("TRAP:", address(trap));
        console.log("CHAIN ID:", block.chainid);
    }
}
