"""환율 스크립트의 로컬 DB 대상을 Docker 없이 확인한다."""

import importlib.util
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("ecos-fx.py")


class EcosFxContainerTests(unittest.TestCase):
    def check_container(self, project_id, expected):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            script = root / "scripts" / SCRIPT.name
            script.parent.mkdir()
            shutil.copyfile(SCRIPT, script)
            config = root / "supabase" / "config.toml"
            config.parent.mkdir()
            config.write_text(f'project_id = "{project_id}"\n', encoding="utf-8")
            spec = importlib.util.spec_from_file_location("ecos_fx", script)
            fx = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(fx)
            with patch.object(fx.subprocess, "run") as run:
                fx.psql("select 1")
            self.assertEqual(run.call_args.args[0][:5], ["docker", "exec", "-i", expected, "psql"])

    def test_default_project_uses_existing_container(self):
        self.check_container("nonanona-local", "supabase_db_nonanona-local")

    def test_separate_project_uses_its_own_container(self):
        self.check_container("nonanona-isolated", "supabase_db_nonanona-isolated")


if __name__ == "__main__":
    unittest.main()
