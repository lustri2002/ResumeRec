import copy
import importlib.util
from pathlib import Path
import tempfile
import json
import unittest

SPEC = importlib.util.spec_from_file_location("build_site", Path(__file__).parents[1] / "build-site.py")
SITE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SITE)


def release(tag, published_at, *, prerelease=True, draft=False):
    name = f"ResumeRec-{tag.removeprefix('v')}-arm64.dmg"
    return {
        "id": 1, "tag_name": tag, "published_at": published_at,
        "prerelease": prerelease, "draft": draft,
        "assets": [{"name": name + suffix, "size": 100, "state": "uploaded",
                    "browser_download_url": f"{SITE.REPOSITORY}/releases/download/{tag}/{name}{suffix}"}
                   for suffix in ("", ".sha256")],
    }


class WebsiteTests(unittest.TestCase):
    def setUp(self):
        self.old = release("v0.2.8-beta.2", "2026-09-28T08:00:00Z")
        self.new = release("v0.2.8-beta.3", "2026-09-29T08:00:00Z")

    def test_newest_beta_across_pages_and_unordered_results(self):
        draft = release("v9.0.0", "2026-10-01T08:00:00Z", draft=True)
        selected = SITE.select_release([[self.new], [draft, self.old]])
        self.assertEqual(selected["tag"], "v0.2.8-beta.3")
        self.assertIn("Free public beta", selected["label"])

    def test_stable_release_updates_label_and_all_links(self):
        stable = release("v0.3.0", "2026-10-01T08:00:00Z", prerelease=False)
        output = SITE.render((SITE.ROOT / "docs/index.html").read_text(), SITE.select_release([self.old, stable]))
        self.assertIn("Free download · v0.3.0", output)
        self.assertEqual(output.count(stable["assets"][0]["browser_download_url"]), 3)
        self.assertIn(f'{SITE.REPOSITORY}/releases/tag/v0.3.0', output)
        self.assertNotIn("v0.2.8-beta.2", output)
        self.assertNotIn("{{", output)

    def test_incomplete_newest_release_fails_instead_of_silently_using_old(self):
        for asset_change in ("missing_checksum", "empty_dmg", "uploading_dmg", "ambiguous_dmg"):
            with self.subTest(asset_change=asset_change):
                latest = copy.deepcopy(self.new)
                if asset_change == "missing_checksum": latest["assets"].pop()
                if asset_change == "empty_dmg": latest["assets"][0]["size"] = 0
                if asset_change == "uploading_dmg": latest["assets"][0]["state"] = "starter"
                if asset_change == "ambiguous_dmg": latest["assets"].append(copy.deepcopy(latest["assets"][0]))
                with self.assertRaises(ValueError): SITE.select_release([self.old, latest])

    def test_unexpected_asset_url_fails(self):
        self.new["assets"][0]["browser_download_url"] = "https://example.com/unrelated.dmg"
        with self.assertRaises(ValueError): SITE.select_release([self.new])

    def test_no_published_releases_fails(self):
        with self.assertRaises(ValueError): SITE.select_release([])
        self.new["draft"] = True
        with self.assertRaises(ValueError): SITE.select_release([self.new])

    def test_removed_template_marker_fails(self):
        template = (SITE.ROOT / "docs/index.html").read_text().replace("{{DOWNLOAD_URL}}", "wrong", 1)
        with self.assertRaises(ValueError): SITE.render(template, SITE.select_release([self.new]))

    def test_build_contains_only_public_assets_and_refuses_to_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            metadata = root / "releases.json"
            metadata.write_text(json.dumps([self.new]))
            output = root / "site"
            SITE.build(metadata, output)
            files = {str(p.relative_to(output)) for p in output.rglob("*") if p.is_file()}
            self.assertEqual(files, {"index.html", *SITE.ASSETS})
            with self.assertRaises(ValueError): SITE.build(metadata, output)


if __name__ == "__main__":
    unittest.main()
