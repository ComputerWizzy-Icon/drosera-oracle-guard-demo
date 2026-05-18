// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {AMMOracle} from "../src/AMMOracle.sol";
import {DroseraResponder} from "../src/DroseraResponder.sol";
import {MockProductionLendingPool} from "../src/MockProductionLendingPool.sol";
import {OracleManipulationTrap} from "../src/OracleManipulationTrap.sol";
import {TestableOracleManipulationTrap} from "../src/TestableOracleManipulationTrap.sol";

contract AttackSimulation is Test {
    AMMOracle internal oracle;
    MockProductionLendingPool internal pool;
    OracleManipulationTrap internal trap;
    DroseraResponder internal responder;

    address internal owner = address(1);
    address internal relayer = address(999);
    address internal attacker = address(666);

    bytes[] internal buffer;

    struct CollectOutput {
        uint8 schemaVersion;
        address pool;
        address oracle;
        uint256 price;
        uint256 oracleUpdatedAt;
        uint256 tvl;
        bool paused;
        uint256 blockNumber;
        uint256 blockTimestamp;
        bool oracleReadOk;
        bool tvlReadOk;
        bool pausedReadOk;
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
        uint256 oracleUpdatedAt,
        uint256 tvl,
        uint256 blk,
        uint256 ts
    ) internal view returns (bytes memory) {
        return
            abi.encode(
                CollectOutput({
                    schemaVersion: 1,
                    pool: address(pool),
                    oracle: address(oracle),
                    price: price,
                    oracleUpdatedAt: oracleUpdatedAt,
                    tvl: tvl,
                    paused: pool.paused(),
                    blockNumber: blk,
                    blockTimestamp: ts,
                    oracleReadOk: true,
                    tvlReadOk: true,
                    pausedReadOk: true
                })
            );
    }

    function test_collect_reads_real_oracle_and_pool() public {
        TestableOracleManipulationTrap testTrap = new TestableOracleManipulationTrap(
                address(oracle),
                address(pool)
            );

        vm.roll(123);
        vm.warp(1_000_000);

        bytes memory raw = testTrap.collect();
        CollectOutput memory out = abi.decode(raw, (CollectOutput));

        assertEq(out.schemaVersion, 1);
        assertEq(out.pool, address(pool));
        assertEq(out.oracle, address(oracle));
        assertEq(out.price, 1e18);
        assertEq(out.tvl, 100 ether);
        assertFalse(out.paused);
        assertEq(out.blockNumber, 123);
        assertEq(out.blockTimestamp, 1_000_000);
        assertTrue(out.oracleReadOk);
        assertTrue(out.tvlReadOk);
        assertTrue(out.pausedReadOk);
        assertGt(out.oracleUpdatedAt, 0);
    }

    function test_spike_and_tvl_drop_triggers_trap() public {
        uint256 basePrice = 1e18;
        uint256 baseTvl = 100 ether;
        uint256 ts = block.timestamp;

        buffer[4] = _sample(basePrice, ts, baseTvl, 100, ts);
        buffer[3] = _sample(basePrice, ts, baseTvl, 101, ts + 12);
        buffer[2] = _sample(basePrice, ts, baseTvl, 102, ts + 24);
        buffer[1] = _sample(basePrice, ts, baseTvl, 103, ts + 36);

        vm.roll(104);
        vm.warp(ts + 48);

        vm.startPrank(attacker);
        oracle.swap1For0(4000 ether);
        pool.depositCollateral{value: 5 ether}();
        pool.borrow(50 ether);
        vm.stopPrank();

        (uint256 attackPrice, uint256 updatedAt) = oracle.getLatestPrice();
        uint256 attackTvl = pool.getTvl();

        buffer[0] = _sample(
            attackPrice,
            updatedAt,
            attackTvl,
            104,
            block.timestamp
        );

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

    function test_malformed_data_does_not_revert() public {
        bytes[] memory malformed = new bytes[](5);

        malformed[0] = hex"1234";
        malformed[1] = hex"";
        malformed[2] = hex"abcdef";
        malformed[3] = hex"01";
        malformed[4] = hex"02";

        (bool trigger, bytes memory payload) = trap.shouldRespond(malformed);

        assertFalse(trigger);
        assertEq(payload.length, 0);
    }

    function test_response_wrong_relayer_fails_correct_relayer_succeeds()
        public
    {
        uint256 basePrice = 1e18;
        uint256 baseTvl = 100 ether;
        uint256 ts = block.timestamp;

        buffer[4] = _sample(basePrice, ts, baseTvl, 100, ts);
        buffer[3] = _sample(basePrice, ts, baseTvl, 101, ts + 12);
        buffer[2] = _sample(basePrice, ts, baseTvl, 102, ts + 24);
        buffer[1] = _sample(basePrice, ts, baseTvl, 103, ts + 36);

        vm.roll(104);
        vm.warp(ts + 48);

        vm.startPrank(attacker);
        oracle.swap1For0(4000 ether);
        pool.depositCollateral{value: 5 ether}();
        pool.borrow(50 ether);
        vm.stopPrank();

        (uint256 attackPrice, uint256 updatedAt) = oracle.getLatestPrice();
        uint256 attackTvl = pool.getTvl();

        buffer[0] = _sample(
            attackPrice,
            updatedAt,
            attackTvl,
            104,
            block.timestamp
        );

        (bool trigger, bytes memory payload) = trap.shouldRespond(buffer);
        assertTrue(trigger, "trap should fire");

        address wrongRelayer = address(12345);

        vm.prank(wrongRelayer);
        vm.expectRevert(bytes("not relayer"));
        responder.executeResponse(payload);

        assertFalse(pool.paused(), "pool should not pause from wrong relayer");

        vm.prank(relayer);
        responder.executeResponse(payload);

        assertTrue(pool.paused(), "pool should pause from correct relayer");
    }

    function test_no_false_positive_on_normal_operation() public {
        uint256 price = 1e18;
        uint256 tvl = 100 ether;
        uint256 ts = block.timestamp;

        for (uint256 i = 0; i < 5; i++) {
            buffer[4 - i] = _sample(
                price,
                ts + (i * 12),
                tvl,
                100 + i,
                ts + (i * 12)
            );
        }

        vm.roll(105);

        (bool trigger, ) = trap.shouldRespond(buffer);

        assertFalse(trigger);
    }

    function test_price_spike_without_tvl_drop_should_not_trigger() public {
        uint256 price = 1e18;
        uint256 tvl = 100 ether;
        uint256 ts = block.timestamp;

        buffer[4] = _sample(price, ts, tvl, 100, ts);
        buffer[3] = _sample(price, ts, tvl, 101, ts + 12);
        buffer[2] = _sample(price, ts, tvl, 102, ts + 24);
        buffer[1] = _sample(price, ts, tvl, 103, ts + 36);

        vm.roll(104);
        vm.warp(ts + 48);

        oracle.swap1For0(500 ether);

        (uint256 manipulatedPrice, uint256 updatedAt) = oracle.getLatestPrice();
        buffer[0] = _sample(
            manipulatedPrice,
            updatedAt,
            tvl,
            104,
            block.timestamp
        );

        (bool trigger, ) = trap.shouldRespond(buffer);

        assertFalse(trigger);
    }

    function test_full_drain_caught() public {
        uint256 basePrice = 1e18;
        uint256 baseTvl = 100 ether;
        uint256 ts = block.timestamp;

        buffer[4] = _sample(basePrice, ts, baseTvl, 100, ts);
        buffer[3] = _sample(basePrice, ts, baseTvl, 101, ts + 12);
        buffer[2] = _sample(basePrice, ts, baseTvl, 102, ts + 24);
        buffer[1] = _sample(basePrice, ts, baseTvl, 103, ts + 36);

        vm.roll(104);
        vm.warp(ts + 48);

        oracle.swap0For1(9000 ether);

        (uint256 crashPrice, uint256 updatedAt) = oracle.getLatestPrice();
        buffer[0] = _sample(crashPrice, updatedAt, 0, 104, block.timestamp);

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
        uint256 ts = block.timestamp;

        buffer[4] = _sample(price, ts, tvl, 100, ts);
        buffer[3] = _sample(price, ts, tvl, 101, ts + 12);
        buffer[2] = _sample(price, ts, tvl, 102, ts + 24);
        buffer[1] = _sample(price, ts, tvl, 103, ts + 36);

        vm.roll(104);
        vm.warp(ts + 48);

        buffer[0] = _sample(price, ts + 48, 85 ether, 104, block.timestamp);

        (bool trigger, ) = trap.shouldRespond(buffer);

        assertFalse(trigger);
    }
}
