// test/Attack.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";
import "forge-std/Test.sol";
import "../src/AMMOracle.sol";
import "../src/LendingPool.sol";
import "../src/OracleManipulationTrap.sol";
import "../src/DroseraResponder.sol";

contract AttackSimulation is Test {
    AMMOracle oracle;
    LendingPool pool;
    OracleManipulationTrap trap;
    DroseraResponder responder;

    address protocolOwner = address(0x1);
    address droseraRelayer = address(0x999);
    address attacker = address(0xBAD);
    address innocentUser = address(0x2);

    function setUp() public {
        vm.startPrank(protocolOwner);
        oracle = new AMMOracle(1000);
        pool = new LendingPool(address(oracle));
        trap = new OracleManipulationTrap(address(oracle), address(pool));
        responder = new DroseraResponder(droseraRelayer);

        pool.setResponder(address(responder));
        vm.stopPrank();

        vm.deal(innocentUser, 100 ether);
        vm.prank(innocentUser);
        pool.depositCollateral{value: 100 ether}();
    }

    function test_DroseraDetectsAndStopsExploit() public {
        // 1. Build a 5-block historical buffer (Blocks 100-104)
        bytes[] memory historicalBuffer = new bytes[](5);

        for (uint i = 0; i < 5; i++) {
            vm.roll(100 + i);
            // Shift existing data back to simulate real ingestion
            for (uint j = 4; j > 0; j--) {
                historicalBuffer[j] = historicalBuffer[j - 1];
            }
            historicalBuffer[0] = trap.collect();
        }

        // 2. THE ATTACK (Block 105)
        vm.roll(105);
        vm.startPrank(attacker);
        vm.deal(attacker, 1 ether);
        pool.depositCollateral{value: 1 ether}();

        // Manipulate price (1000 -> 90000)
        oracle.manipulatePrice(90000);
        pool.borrow(50 ether);
        vm.stopPrank();

        // 3. DROSERA DETECTION
        // Shift buffer and add the attack block state
        for (uint j = 4; j > 0; j--) {
            historicalBuffer[j] = historicalBuffer[j - 1];
        }
        historicalBuffer[0] = trap.collect();

        (bool trigger, bytes memory responseCalldata) = trap.shouldRespond(
            historicalBuffer
        );

        assertTrue(trigger, "Trap failed to detect price spike/TVL drop");

        // 4. AUTOMATED RESPONSE (Block 106)
        vm.roll(106);
        address targetPool = abi.decode(responseCalldata, (address));
        vm.prank(droseraRelayer);
        responder.executeResponse(targetPool);

        // 5. VERIFY SECURITY
        assertTrue(pool.paused(), "Protocol was not paused!");

        // SUCCESS: OpenZeppelin v5 uses the custom error EnforcedPause()
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        pool.borrow(1 ether);
        vm.stopPrank();
    }
}
