"""Fast, simulator-independent checks for the dequantization golden model."""

from __future__ import annotations

import unittest

from p3llm_dequant_model import (
    DequantGolden,
    add_fp32_rne,
    fp32_scale_to_fp16,
    int32_scale_to_fp32,
    pack_fp16_exact,
    pack_fp32_exact,
    unpack_fp16,
)
from p3llm_pcu_model import NUM_PES, OP_LINEAR, OP_PV, OP_QK


class DequantModelTest(unittest.TestCase):
    def test_fp16_unpack_including_subnormal(self) -> None:
        self.assertEqual(unpack_fp16(0x3C00).coefficient, 1024)
        self.assertEqual(unpack_fp16(0x3C00).exponent, -10)
        self.assertEqual(unpack_fp16(0x0001).coefficient, 1)
        self.assertEqual(unpack_fp16(0x0001).exponent, -24)
        self.assertEqual(unpack_fp16(0x8001).coefficient, -1)
        self.assertEqual(unpack_fp16(0x0400).coefficient, 1024)
        self.assertEqual(unpack_fp16(0x0400).exponent, -24)

    def test_fp16_rne_boundaries(self) -> None:
        cases = (
            # Exactly halfway between 1.0 and the next binary16 value: the
            # low endpoint has an even significand.
            ((1 << 11) + 1, -11, 0x3C00),
            # The next halfway case rounds upward to the even significand.
            ((1 << 11) + 3, -11, 0x3C02),
            (-((1 << 11) + 1), -11, 0xBC00),
            # Half of the minimum subnormal rounds to even zero; 1.5 ulp
            # rounds to subnormal significand two.
            (1, -25, 0x0000),
            (3, -25, 0x0002),
            # Tie between max-subnormal (odd) and min-normal (even).
            (2047, -25, 0x0400),
            # Halfway above max-finite rounds to infinity.
            (65520, 0, 0x7C00),
        )
        for coefficient, exponent, expected in cases:
            with self.subTest(coefficient=coefficient, exponent=exponent):
                self.assertEqual(
                    pack_fp16_exact(coefficient, exponent), expected
                )

    def test_fp32_rne_ties_and_addition_rounding(self) -> None:
        self.assertEqual(
            pack_fp32_exact((1 << 24) + 1, -24), 0x3F800000
        )
        self.assertEqual(
            pack_fp32_exact((1 << 24) + 3, -24), 0x3F800002
        )

        # 1.0 + 2**-24 is exactly a binary32 halfway case and stays at 1.0.
        self.assertEqual(
            add_fp32_rne(0x3F800000, 0x33800000), 0x3F800000
        )
        # Exact cancellation must return +zero in RNE mode.
        self.assertEqual(
            add_fp32_rne(0x3F800000, 0xBF800000), 0x00000000
        )

    def test_mode_offsets_and_subnormal_scale_are_not_flushed(self) -> None:
        self.assertEqual(
            int32_scale_to_fp32(4096, 0x3C00, -12), 0x3F800000
        )
        self.assertEqual(
            int32_scale_to_fp32(2048, 0x3C00, -11), 0x3F800000
        )
        self.assertEqual(
            int32_scale_to_fp32(1 << 19, 0x3C00, -19), 0x3F800000
        )

        # 2**24 * min-subnormal * 2**-12 = 2**-12.  DAZ/FTZ logic would
        # incorrectly produce zero here.
        self.assertEqual(
            int32_scale_to_fp32(1 << 24, 0x0001, -12), 0x39800000
        )

    def test_final_fp16_rounding_and_subnormal_result(self) -> None:
        self.assertEqual(fp32_scale_to_fp16(0x3F800000, 0x3C00), 0x3C00)
        # 2**-24 is exactly the minimum FP16 subnormal.
        self.assertEqual(fp32_scale_to_fp16(0x33800000, 0x3C00), 0x0001)
        self.assertEqual(fp32_scale_to_fp16(0x33000000, 0x3C00), 0x0000)

    def test_multigroup_state_clear_and_lane_order(self) -> None:
        for mode, raw_one in (
            (OP_LINEAR, 1 << 12),
            (OP_QK, 1 << 11),
            (OP_PV, 1 << 19),
        ):
            with self.subTest(mode=mode):
                model = DequantGolden()
                raw0 = tuple((pe + 1) * raw_one for pe in range(NUM_PES))
                raw1 = tuple((NUM_PES - pe) * raw_one for pe in range(NUM_PES))
                scale0 = tuple(
                    0x3C00 if pe & 1 else 0x3800 for pe in range(NUM_PES)
                )
                scale1 = tuple(
                    0x3800 if pe & 1 else 0x3C00 for pe in range(NUM_PES)
                )

                first = model.accept_group(
                    raw0,
                    scale0,
                    mode,
                    fp_acc_clear=True,
                    dot_last=False,
                    final_scale16=0x3C00,
                )
                self.assertIsNone(first.result16)
                second = model.accept_group(
                    raw1,
                    scale1,
                    mode,
                    fp_acc_clear=False,
                    dot_last=True,
                    final_scale16=0x3C00,
                )
                self.assertIsNotNone(second.result16)
                assert second.result16 is not None
                self.assertGreaterEqual(len(set(second.result16)), 8)
                self.assertNotEqual(second.result16[0], second.result16[1])

                # A new dot explicitly clears all prior FP32 state.
                cleared = model.accept_group(
                    (raw_one,) * NUM_PES,
                    (0x3C00,) * NUM_PES,
                    mode,
                    fp_acc_clear=True,
                    dot_last=True,
                    final_scale16=0x3C00,
                )
                self.assertEqual(cleared.result16, (0x3C00,) * NUM_PES)

    def test_nonfinite_scale_is_rejected_by_the_contract(self) -> None:
        with self.assertRaises(ValueError):
            int32_scale_to_fp32(1, 0x7C00, -12)
        with self.assertRaises(ValueError):
            fp32_scale_to_fp16(0, 0x7E00)
        with self.assertRaises(ValueError):
            int32_scale_to_fp32(1, 0xBC00, -12)
        with self.assertRaises(ValueError):
            fp32_scale_to_fp16(0, 0x8000)


if __name__ == "__main__":
    unittest.main()
