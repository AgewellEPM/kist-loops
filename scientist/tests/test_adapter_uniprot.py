"""UniProt adapter tests — mocked transport; the live probe lives in run_live.py."""
import io
import json
import unittest

from scientist.adapters.uniprot import AdapterError, observe


class FakeResponse(io.BytesIO):
    def __init__(self, body, status=200):
        super().__init__(body)
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


ENTRY = {
    "primaryAccession": "P69905",
    "sequence": {"length": 142},
    "proteinDescription": {"recommendedName": {"fullName": {"value": "Hemoglobin subunit alpha"}}},
    "features": [
        {"type": "Initiator methionine", "description": "Removed",
         "location": {"start": {"value": 1}, "end": {"value": 1}}},
        {"type": "Chain", "description": "Hemoglobin subunit alpha",
         "location": {"start": {"value": 2}, "end": {"value": 142}}},
    ],
}


def fake_urlopen(body, status=200):
    def opener(url, timeout=0):
        return FakeResponse(body, status=status)
    return opener


class UniProtAdapterTests(unittest.TestCase):
    def test_extracts_typed_observations(self):
        observations, digest, meta = observe(
            {"key": "P69905", "fields": ["sequence_length", "mature_chain_length",
                                          "initiator_met_removed"]},
            urlopen=fake_urlopen(json.dumps(ENTRY).encode()))
        self.assertEqual(observations["uniprot:P69905:sequence_length"], 142)
        self.assertEqual(observations["uniprot:P69905:mature_chain_length"], 141)
        self.assertTrue(observations["uniprot:P69905:initiator_met_removed"])
        self.assertEqual(len(digest), 64)
        self.assertEqual(meta["primary_accession"], "P69905")

    def test_empty_200_body_is_an_error_never_an_observation(self):
        with self.assertRaises(AdapterError) as caught:
            observe({"key": "FAKE123", "fields": ["sequence_length"]},
                    urlopen=fake_urlopen(b""))
        self.assertIn("EMPTY 200", str(caught.exception))

    def test_wrong_accession_answer_is_refused(self):
        wrong = dict(ENTRY, primaryAccession="P00000")
        with self.assertRaises(AdapterError):
            observe({"key": "P69905", "fields": ["sequence_length"]},
                    urlopen=fake_urlopen(json.dumps(wrong).encode()))

    def test_unsupported_field_fails_fast(self):
        with self.assertRaises(AdapterError):
            observe({"key": "P69905", "fields": ["favourite_colour"]},
                    urlopen=fake_urlopen(json.dumps(ENTRY).encode()))


if __name__ == "__main__":
    unittest.main()
