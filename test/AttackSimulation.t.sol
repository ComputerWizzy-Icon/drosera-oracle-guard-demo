// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

import {AMMOracle} from "../src/AMMOracle.sol";
import {MockProductionLendingPool} from "../src/MockProductionLendingPool.sol";
import {DroseraResponder} from "../src/DroseraResponder.sol";
import {OracleManipulationTrap} from "../src/OracleManipulationTrap.sol";

contract AttackSimulation is Test {
    AMMOracle oracle;
    MockProductionLendingPool pool;
    OracleManipulationTrap trap;
    DroseraResponder responder;

    address owner = address(1);
    address relayer = address(999);
    address attacker = address(666);

    bytes[] buffer;

    struct CollectOutput {
        address pool;
        address oracle;
        uint256 price;
        uint256 tvl;
        bool paused;
        uint256 blockNumber;
    }

    function setUp() public {
        vm.chainId(560048);

        vm.startPrank(owner);

        oracle = new AMMOracle(1000 ether, 1000 ether);

        pool = new MockProductionLendingPool(owner, address(oracle));

        responder = new DroseraResponder(owner, relayer);

        pool.setResponder(address(responder));

        vm.deal(owner, 200 ether);
        pool.fundLiquidity{value: 100 ether}();

        responder.setApprovedPool(address(pool), true);

        vm.stopPrank();

        trap = new OracleManipulationTrap();

        vm.deal(attacker, 50 ether);
        buffer = new bytes[](5);
    }

    function _sample(
        uint256 price,
        uint256 tvl,
        uint256 blk
    ) internal view returns (bytes memory) {
        return
            abi.encode(
                CollectOutput({
                    pool: address(pool),
                    oracle: address(oracle),
                    price: price,
                    tvl: tvl,
                    paused: pool.paused(),
                    blockNumber: blk
                })
            );
    }

    // =========================================================
    // CORE ATTACK TEST
    // =========================================================

    function test_spike_and_tvl_drop_triggers_trap() public {
        uint256 basePrice = 1e18;
        uint256 baseTvl = 100 ether;

        buffer[4] = _sample(basePrice, baseTvl, 100);
        buffer[3] = _sample(basePrice, baseTvl, 101);
        buffer[2] = _sample(basePrice, baseTvl, 102);
        buffer[1] = _sample(basePrice, baseTvl, 103);

        vm.roll(104);

        vm.startPrank(attacker);

        oracle.swap1For0(4000 ether);
        pool.depositCollateral{value: 5 ether}();
        pool.borrow(50 ether);

        vm.stopPrank();

        // ✅ FIXED: correct tuple destructuring
        (uint256 attackPrice, ) = oracle.getLatestPrice();
        uint256 attackTvl = pool.getTvl();

        buffer[0] = _sample(attackPrice, attackTvl, 104);

        assertTrue(attackPrice >= basePrice * 5, "price spike expected");
        assertTrue(attackTvl < (baseTvl * 9) / 10, "TVL drop expected");

        (bool trigger, bytes memory payload) = trap.shouldRespond(buffer);

        assertTrue(trigger, "trap should fire");

        OracleManipulationTrap.ResponsePayload memory resp = abi.decode(
            payload,
            (OracleManipulationTrap.ResponsePayload)
        );

        assertEq(resp.pool, address(pool));

        assertEq(
            uint256(resp.reason),
            uint256(OracleManipulationTrap.Reason.PriceSpikeAndTvlDrop)
        );

        vm.prank(relayer);
        responder.executeResponse(payload);

        assertTrue(pool.paused(), "pool should be paused");

        vm.prank(relayer);
        responder.executeResponse(payload);

        assertTrue(pool.paused(), "idempotent pause");
    }

    // =========================================================
    // NEGATIVE CASES
    // =========================================================

    function test_no_false_positive_on_normal_operation() public {
        uint256 price = 1e18;
        uint256 tvl = 100 ether;

        for (uint256 i = 0; i < 5; i++) {
            buffer[4 - i] = _sample(price, tvl, 100 + i);
        }

        vm.roll(105);

        (bool trigger, ) = trap.shouldRespond(buffer);

        assertFalse(trigger);
    }

    function test_price_spike_without_tvl_drop_should_not_trigger() public {
        uint256 price = 1e18;
        uint256 tvl = 100 ether;

        buffer[4] = _sample(price, tvl, 100);
        buffer[3] = _sample(price, tvl, 101);
        buffer[2] = _sample(price, tvl, 102);
        buffer[1] = _sample(price, tvl, 103);

        vm.roll(104);

        oracle.swap1For0(500 ether);

        // ✅ FIXED
        (uint256 p, ) = oracle.getLatestPrice();

        buffer[0] = _sample(p, tvl, 104);

        (bool trigger, ) = trap.shouldRespond(buffer);

        assertFalse(trigger);
    }

    function test_full_drain_caught() public {
        uint256 basePrice = 1e18;
        uint256 baseTvl = 100 ether;

        buffer[4] = _sample(basePrice, baseTvl, 100);
        buffer[3] = _sample(basePrice, baseTvl, 101);
        buffer[2] = _sample(basePrice, baseTvl, 102);
        buffer[1] = _sample(basePrice, baseTvl, 103);

        vm.roll(104);

        oracle.swap0For1(9000 ether);

        // ✅ FIXED
        (uint256 crashPrice, ) = oracle.getLatestPrice();

        buffer[0] = _sample(crashPrice, 0, 104);

        (bool trigger, bytes memory payload) = trap.shouldRespond(buffer);

        assertTrue(trigger);

        OracleManipulationTrap.ResponsePayload memory resp = abi.decode(
            payload,
            (OracleManipulationTrap.ResponsePayload)
        );

        assertEq(
            uint256(resp.reason),
            uint256(OracleManipulationTrap.Reason.PriceCrashAndTvlDrop)
        );

        assertEq(resp.currentTvl, 0);
    }

    function test_tvl_drop_alone_should_not_trigger() public {
        uint256 price = 1e18;
        uint256 tvl = 100 ether;

        buffer[4] = _sample(price, tvl, 100);
        buffer[3] = _sample(price, tvl, 101);
        buffer[2] = _sample(price, tvl, 102);
        buffer[1] = _sample(price, tvl, 103);

        vm.roll(104);

        buffer[0] = _sample(price, 85 ether, 104);

        (bool trigger, ) = trap.shouldRespond(buffer);

        assertFalse(trigger);
    }
}
