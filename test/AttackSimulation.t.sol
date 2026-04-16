// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

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

    address owner = address(1);
    address relayer = address(999);
    address attacker = address(666);

    bytes[] buffer;

    function setUp() public {
        vm.startPrank(owner);

        // Deploy with 1:1 price
        oracle = new AMMOracle(1000 ether, 1000 ether);
        pool = new LendingPool(address(oracle));

        // Seed pool with liquidity
        vm.deal(address(pool), 100 ether);

        trap = new OracleManipulationTrap(address(oracle), address(pool));
        responder = new DroseraResponder(relayer, address(pool));

        pool.setResponder(address(responder));
        vm.stopPrank();

        vm.deal(attacker, 10 ether);

        // FIX 1: Correct initialization of bytes array
        buffer = new bytes[](5);
    }

    function test_attack_detected_and_stopped() public {
        // 1. Build baseline history (1.0 price)
        for (uint i = 0; i < 5; i++) {
            vm.roll(100 + i);
            for (uint j = 4; j > 0; j--) {
                buffer[j] = buffer[j - 1];
            }
            buffer[0] = trap.collect();
        }

        // 2. Attack phase
        vm.roll(105);
        vm.startPrank(attacker);

        pool.depositCollateral{value: 1 ether}();

        // FIX 2: Manually manipulate storage to force a PRICE SPIKE (10x)
        // oracle.swap(900 ether) increases reserve0, crashing the price.
        // Instead, we set reserve0 low and reserve1 high.
        // reserve0 = slot 0, reserve1 = slot 1
        vm.store(
            address(oracle),
            bytes32(uint256(0)),
            bytes32(uint256(100 ether))
        );
        vm.store(
            address(oracle),
            bytes32(uint256(1)),
            bytes32(uint256(1000 ether))
        );
        // New Price = 10.0 (1000/100)

        // With 1 ETH collateral and 10x price, we have 10 ETH borrow power.
        // Borrowing 15 ETH would fail, so we borrow 8 ETH.
        // Wait! To trigger the Trap (TVL drop > 10%), we need to borrow more than 10% of total pool.
        // Pool has ~101 ETH. Let's borrow 12 ETH.
        // To borrow 12 ETH, we need our collateral to be worth more. Let's set price to 20x.
        vm.store(
            address(oracle),
            bytes32(uint256(0)),
            bytes32(uint256(50 ether))
        );
        // Price is now 20.0. 1 ETH collateral = 20 ETH borrow power.

        pool.borrow(15 ether); // 15% TVL drop.

        vm.stopPrank();

        // 3. Update buffer post-attack
        for (uint j = 4; j > 0; j--) {
            buffer[j] = buffer[j - 1];
        }
        buffer[0] = trap.collect();

        // 4. Detection
        (bool trigger, bytes memory data) = trap.shouldRespond(buffer);
        assertTrue(
            trigger,
            "Trap did not trigger: Need Spike (>5x) AND TVL drop (>10%)"
        );

        // 5. Response
        vm.prank(relayer);
        responder.executeResponse(abi.decode(data, (address)));

        // 6. Verify success
        assertTrue(pool.paused(), "Pool not paused");
    }
}
