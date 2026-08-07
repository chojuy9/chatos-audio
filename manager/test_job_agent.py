import unittest
from unittest import mock

import job_agent


class JobAgentTests(unittest.TestCase):
    def test_transcription_is_always_advertised(self):
        with mock.patch.object(job_agent, "LYRICS_ENABLED", False):
            self.assertEqual(job_agent.supported_tasks(), ["transcription"])

    def test_lyrics_requires_both_flag_and_separator(self):
        with (
            mock.patch.object(job_agent, "LYRICS_ENABLED", True),
            mock.patch.object(job_agent, "CUSTOM_SEPARATOR", ""),
            mock.patch.object(job_agent.shutil, "which", return_value=None),
        ):
            self.assertEqual(job_agent.supported_tasks(), ["transcription"])
        with (
            mock.patch.object(job_agent, "LYRICS_ENABLED", True),
            mock.patch.object(job_agent, "CUSTOM_SEPARATOR", "separator {input} {output}"),
        ):
            self.assertEqual(job_agent.supported_tasks(), ["transcription", "lyrics"])

    def test_worker_filename_cannot_escape_temp_directory(self):
        self.assertEqual(job_agent._safe_name("../../secret.wav"), "secret.wav")
        self.assertEqual(job_agent._safe_name("노래 파일.mp3"), "노래_파일.mp3")

    def test_custom_separator_placeholders_are_individual_arguments(self):
        self.assertEqual(
            job_agent._replace_all("--output={output}", {"{output}": "/tmp/vocals.wav"}),
            "--output=/tmp/vocals.wav",
        )


if __name__ == "__main__":
    unittest.main()
