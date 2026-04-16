// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AMMOracle} from "../src/AMMOracle.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {DroseraResponder} from "../src/DroseraResponder.sol";

contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address relayer = vm.envOr("RELAYER_ADDRESS", deployer);

        vm.startBroadcast(pk);

        AMMOracle oracle = new AMMOracle(1000 ether, 1000 ether);
        LendingPool pool = new LendingPool(deployer, address(oracle));
        DroseraResponder responder = new DroseraResponder(
            deployer,
            relayer,
            address(pool)
        );

        pool.setResponder(address(responder));

        vm.stopBroadcast();

        console.log("ORACLE:    ", address(oracle));
        console.log("POOL:      ", address(pool));
        console.log("RESPONDER: ", address(responder));
    }
}
