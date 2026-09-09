import unittest
from lifecycle import status


class Lifecycle(unittest.TestCase):
    # Asserts the current approved contract in requirements.md:
    # native -> "platform-pending"; external -> "verified".

    def test_native(self):
        self.assertEqual(status("native"), "platform-pending")

    def test_external(self):
        self.assertEqual(status("external"), "verified")


if __name__ == "__main__":
    unittest.main()
