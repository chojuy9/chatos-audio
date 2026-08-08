import tempfile
import unittest
from pathlib import Path
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
            mock.patch.object(job_agent.shutil, "which", return_value="/usr/bin/separator"),
        ):
            self.assertEqual(job_agent.supported_tasks(), ["transcription", "lyrics"])

    def test_custom_separator_must_point_to_an_executable(self):
        with (
            mock.patch.object(job_agent, "CUSTOM_SEPARATOR", "missing-separator {input} {output}"),
            mock.patch.object(job_agent.shutil, "which", return_value=None),
        ):
            self.assertFalse(job_agent.separator_available())

    def test_demucs_can_be_explicitly_configured_for_cpu(self):
        with (
            mock.patch.object(job_agent, "CUSTOM_SEPARATOR", ""),
            mock.patch.object(job_agent, "LYRICS_DEVICE", "cpu"),
            mock.patch.object(job_agent.shutil, "which", return_value="/venv/bin/demucs"),
        ):
            self.assertTrue(job_agent.separator_available())

    def test_worker_filename_cannot_escape_temp_directory(self):
        self.assertEqual(job_agent._safe_name("../../secret.wav"), "secret.wav")
        self.assertEqual(job_agent._safe_name("노래 파일.mp3"), "노래_파일.mp3")

    def test_custom_separator_placeholders_are_individual_arguments(self):
        self.assertEqual(
            job_agent._replace_all("--output={output}", {"{output}": "/tmp/vocals.wav"}),
            "--output=/tmp/vocals.wav",
        )


class JobAgentAsyncTests(unittest.IsolatedAsyncioTestCase):
    async def test_demucs_separator_uses_configured_model_device_and_output(self):
        class Process:
            returncode = 0

            async def communicate(self):
                return b"ok", b""

        with tempfile.TemporaryDirectory() as raw_dir:
            work_dir = Path(raw_dir)
            source = work_dir / "song.mp3"
            source.write_bytes(b"audio")
            seen = {}

            async def fake_exec(*command, **kwargs):
                seen["command"] = command
                seen["env"] = kwargs.get("env")
                output = work_dir / "demucs" / "test-model" / "song" / "vocals.wav"
                output.parent.mkdir(parents=True)
                output.write_bytes(b"RIFF" + bytes(100))
                return Process()

            with (
                mock.patch.object(job_agent, "CUSTOM_SEPARATOR", ""),
                mock.patch.object(job_agent, "LYRICS_MODEL", "test-model"),
                mock.patch.object(job_agent, "LYRICS_DEVICE", "cuda"),
                mock.patch.object(job_agent.shutil, "which", return_value="/venv/bin/demucs"),
                mock.patch.object(job_agent.asyncio, "create_subprocess_exec", side_effect=fake_exec),
            ):
                output = await job_agent._run_separator(source, work_dir)

            self.assertEqual(output.name, "vocals.wav")
            self.assertIn("test-model", seen["command"])
            self.assertIn("cuda", seen["command"])
            self.assertIsInstance(seen["env"], dict)


if __name__ == "__main__":
    unittest.main()
