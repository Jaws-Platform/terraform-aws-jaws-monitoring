import unittest

from normalizer.tags import promote


class PromoteTest(unittest.TestCase):
    def test_promotes_exact_keys(self):
        self.assertEqual(
            promote({"Project": "braveheart", "Owner": "x"}, ["Project", "Component"]),
            {"Project": "braveheart", "Component": None},
        )

    def test_promotes_user_prefixed_keys(self):
        self.assertEqual(promote({"user:Project": "a"}, ["Project"]), {"Project": "a"})
        self.assertEqual(promote({"user_project": "b"}, ["Project"]), {"Project": "b"})

    def test_exact_key_wins_over_prefixed_forms(self):
        self.assertEqual(promote({"user:Project": "a", "Project": "b"}, ["Project"]), {"Project": "b"})

    def test_blank_values_and_missing_maps_are_untagged(self):
        self.assertEqual(promote({"Project": "  "}, ["Project"]), {"Project": None})
        self.assertEqual(promote(None, ["Project"]), {"Project": None})


if __name__ == "__main__":
    unittest.main()
