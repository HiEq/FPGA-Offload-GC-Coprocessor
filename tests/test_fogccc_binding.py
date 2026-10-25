"""Unit tests for the Python binding's decision logic, without hardware.

``python/fogccc.py`` loads ``libfogccc.so`` at import time, so the module is
imported here with ``ctypes.CDLL`` stubbed out and ``barrier_verify`` is bound
to a fake object that supplies ``read_mark``.  Set ``FOGCCC_PATH`` to test a
different copy of the module (used for the negative control).

    python3 tests/test_fogccc_binding.py -v

    # negative control: the pre-fix reading of the sentinel
    git show 933d04bc:python/fogccc.py > /tmp/fogccc_old.py
    FOGCCC_PATH=/tmp/fogccc_old.py python3 tests/test_fogccc_binding.py -v
"""
import importlib.util
import os
import sys
import types
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULE = os.environ.get('FOGCCC_PATH', os.path.join(ROOT, 'python', 'fogccc.py'))

PROBE_FAILED = 0xFFFFFFFF


class _StubFunc(object):
    restype = None
    argtypes = []


class _StubLib(object):
    def __getattr__(self, name):
        fn = _StubFunc()
        setattr(self, name, fn)
        return fn


def _load_module(path):
    """Import fogccc.py with the shared library stubbed out."""
    with mock.patch('ctypes.CDLL', lambda *a, **k: _StubLib()), \
            mock.patch('os.path.exists', lambda p: p.endswith('libfogccc.so')):
        spec = importlib.util.spec_from_file_location('fogccc_under_test', path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    return mod


class _FakeDev(object):
    """Minimal stand-in: only read_mark is needed by barrier_verify."""

    def __init__(self, marks):
        self._marks = marks
        self.calls = []

    def read_mark(self, obj_id):
        self.calls.append(obj_id)
        return self._marks[obj_id]


class BarrierVerifyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = _load_module(MODULE)

    def verify(self, marks, ids):
        dev = _FakeDev(marks)
        return self.mod.FOGCCC.barrier_verify(dev, ids), dev

    def test_all_marked_is_true(self):
        ok, dev = self.verify({1: 1, 2: 1, 3: 1}, [1, 2, 3])
        self.assertTrue(ok)
        self.assertEqual(dev.calls, [1, 2, 3])

    def test_one_unmarked_is_false(self):
        ok, _ = self.verify({1: 1, 2: 0}, [1, 2])
        self.assertFalse(ok)

    def test_probe_sentinel_is_unverified(self):
        """0xFFFFFFFF is 'probe failed', not 'marked'.

        The pre-fix implementation used ``all(self.read_mark(i) ...)``, which
        treated the sentinel as truthy and reported success on a failed probe.
        """
        ok, _ = self.verify({1: 1, 2: PROBE_FAILED}, [1, 2])
        self.assertFalse(ok, 'a failed probe must not count as a mark')

    def test_only_sentinels_is_false(self):
        ok, _ = self.verify({7: PROBE_FAILED}, [7])
        self.assertFalse(ok)

    def test_empty_set_is_vacuously_true(self):
        ok, dev = self.verify({}, [])
        self.assertTrue(ok)
        self.assertEqual(dev.calls, [])

    def test_ids_are_coerced(self):
        ok, dev = self.verify({4: 1}, ['4'])
        self.assertTrue(ok)
        self.assertEqual(dev.calls, [4])


if __name__ == '__main__':
    unittest.main()
