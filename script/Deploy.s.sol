// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import {AMMOracle} from "../src/AMMOracle.sol";
import {MockProductionLendingPool} from "../src/MockProductionLendingPool.sol";
import {DroseraResponder} from "../src/DroseraResponder.sol";
import {OracleManipulationTrap} from "../src/OracleManipulationTrap.sol";

contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address relayer = vm.envAddress("RELAYER_ADDRESS");

        vm.startBroadcast(pk);

        address deployer = vm.addr(pk);

        AMMOracle oracle = new AMMOracle(1_000 ether, 1_000 ether);
        MockProductionLendingPool pool = new MockProductionLendingPool(
            deployer,
            address(oracle)
        );
        pool.fundLiquidity{value: 0.05 ether}();

        DroseraResponder responder = new DroseraResponder(
            deployer,
            relayer,
            20
        );
        responder.setApprovedPool(address(pool), true);
        pool.setResponder(address(responder));

        OracleManipulationTrap trap = new OracleManipulationTrap();

        vm.stopBroadcast();

        require(address(pool) != address(0), "pool failed");
        require(address(oracle) != address(0), "oracle failed");
        require(address(responder) != address(0), "responder failed");
        require(address(trap) != address(0), "trap failed");

        console.log("====================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("====================================");
        console.log("ORACLE:   ", address(oracle));
        console.log("POOL:     ", address(pool));
        console.log("RESPONDER:", address(responder));
        console.log("TRAP:     ", address(trap));
        console.log("CHAIN ID:", block.chainid);
        console.log("====================================");
        console.log("NEXT STEP:");
        console.log("Update OracleManipulationTrap configForChain()");
        console.log("====================================");
    }
}
