// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "../src/AMMOracle.sol";
import "../src/LendingPool.sol";
import "../src/DroseraResponder.sol";

contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);

        // 1. Deploy oracle (AMM simulation)
        AMMOracle oracle = new AMMOracle(1000 ether, 1000 ether);

        // 2. Deploy lending pool
        LendingPool pool = new LendingPool(address(oracle));

        // 3. Deploy responder
        DroseraResponder responder = new DroseraResponder(
            msg.sender,
            address(pool)
        );

        // 4. Wire contracts
        pool.setResponder(address(responder));

        vm.stopBroadcast();

        console.log("ORACLE:", address(oracle));
        console.log("POOL:", address(pool));
        console.log("RESPONDER:", address(responder));
    }
}
