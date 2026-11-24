"""The design lint counts raw values outside DesignSystem and fails only on new drift."""

from pathlib import Path
import contextlib
import importlib.util
import io
import json
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("design_lint", ROOT / "scripts/design_lint.py")
lint = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lint)


def kinds(source):
    return [kind for kind, _ in lint.findings(source)]


class FindingsTests(unittest.TestCase):
    def test_counts_raw_padding_and_edge_insets(self):
        source = "\n".join([
            "a.padding(12)",
            "a.padding(.horizontal, 14)",
            "a.padding([.top, .bottom], 8)",
            "a.safeAreaPadding(.bottom, 6)",
            "a.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))",
        ])
        self.assertEqual(kinds(source), ["padding"] * 7)

    def test_tokens_zero_and_expressions_are_not_drift(self):
        source = "\n".join([
            "a.padding(kit.space(.s4))",
            "a.padding(.horizontal, kit.space(.s3))",
            "a.padding(0)",
            "VStack(spacing: 0) {}",
            "HStack(spacing: kit.space(.s2)) {}",
            "RoundedRectangle(cornerRadius: kit.phoneRadius(.lg))",
            "RoundedRectangle(cornerRadius: ChatLayout.runRadius)",
            "a.font(kit.font(.body))",
            "a.motion(.quick, value: x)",
            "withMotion(.send) { send() }",
            "Text(\"x\").lineSpacing(4)",
        ])
        self.assertEqual(kinds(source), [])

    def test_counts_spacing_radius_and_font_size(self):
        source = "\n".join([
            "VStack(alignment: .leading, spacing: 6) {}",
            "Grid(horizontalSpacing: 8, verticalSpacing: 4) {}",
            "RoundedRectangle(cornerRadius: 14, style: .continuous)",
            "a.cornerRadius(9)",
            "UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 0)",
            "UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(topLeading: 6, topTrailing: 18))",
            "a.font(.system(size: 16, weight: .light))",
        ])
        self.assertEqual(kinds(source), ["spacing", "spacing", "spacing", "radius", "radius",
                                         "radius", "radius", "radius", "font-size"])

    def test_counts_bare_curves_default_and_bare_with_animation(self):
        source = "\n".join([
            "withAnimation(.easeOut(duration: 0.2)) { x = true }",
            "a.animation(reduceMotion ? nil : .snappy(duration: 0.25), value: v)",
            "withAnimation(.snappy) { t.toggle() }",
            "withAnimation { proxy.scrollTo(id) }",
            "a.animation(.default, value: v)",
            "withAnimation(.timingCurve(0.37, 0, 0.63, 1, duration: 0.8)) {}",
            "let s: Animation = .interpolatingSpring(stiffness: 1, damping: 1)",
        ])
        self.assertEqual(kinds(source), ["animation"] * 7)

    def test_ignores_comments_strings_and_allowed_lines(self):
        source = "\n".join([
            "// a.padding(12) is how it used to be",
            "/* withAnimation { } /* nested .spring */ still a comment */",
            'let s = "a.padding(12) .easeOut"',
            'let m = """',
            "RoundedRectangle(cornerRadius: 14)",
            '"""',
            "a.padding(.top, 1) // design-lint: allow: hairline",
            "a.padding(.top, 2)",
        ])
        self.assertEqual(lint.findings(source), [("padding", 8)])


class CheckTests(unittest.TestCase):
    def repo(self, files, baseline=None):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        for relative, text in files.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        (root / "scripts").mkdir(exist_ok=True)
        if baseline is not None:
            (root / lint.BASELINE).write_text(json.dumps({"files": baseline}))
        return root

    def run_check(self, root):
        out = io.StringIO()
        code = lint.check(root, root / lint.BASELINE, out=out)
        return code, out.getvalue()

    def test_design_system_is_exempt(self):
        root = self.repo({"ios/App/DesignSystem/Motion.swift": "x.animation(.snappy(duration: 0.2), value: v)",
                          "ios/App/Home/Row.swift": "a.padding(kit.space(.s4))"}, baseline={})
        self.assertEqual(self.run_check(root)[0], 0)

    def test_new_file_with_raw_values_fails_with_locations(self):
        root = self.repo({"ios/App/Home/New.swift": "a\nHStack(spacing: 7) {}"}, baseline={})
        code, out = self.run_check(root)
        self.assertEqual(code, 1)
        self.assertIn("ios/App/Home/New.swift: spacing 1 > baseline 0", out)
        self.assertIn("ios/App/Home/New.swift:2: raw spacing", out)

    def test_existing_counts_pass_and_any_change_fails(self):
        files = {"ios/App/Chat/Bubble.swift": "a.padding(12)\na.padding(8)"}
        at = self.repo(files, baseline={"ios/App/Chat/Bubble.swift": {"padding": 2}})
        self.assertEqual(self.run_check(at)[0], 0)
        over = self.repo(files, baseline={"ios/App/Chat/Bubble.swift": {"padding": 1}})
        code, out = self.run_check(over)
        self.assertEqual(code, 1)
        self.assertIn("padding 2 > baseline 1", out)
        # Fewer than the baseline (a migration, a deleted file) fails until --update.
        under = self.repo(files, baseline={"ios/App/Chat/Bubble.swift": {"padding": 3},
                                           "ios/App/Chat/Gone.swift": {"radius": 1}})
        code, out = self.run_check(under)
        self.assertEqual(code, 1)
        self.assertIn("padding 2 < baseline 3", out)
        self.assertIn("ios/App/Chat/Gone.swift: radius 0 < baseline 1", out)
        self.assertIn("--update", out)
        self.assertNotIn(" > baseline", out)

    def test_update_writes_a_baseline_the_check_accepts(self):
        root = self.repo({"ios/App/Store/Shelf.swift": "VStack(spacing: 6) {}.font(.system(size: 12))",
                          "ios/App/Store/Clean.swift": "a.padding(kit.space(.s4))"})
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(lint.main(["--update", "--root", str(root)]), 0)
        data = json.loads((root / lint.BASELINE).read_text())
        self.assertEqual(data["files"], {"ios/App/Store/Shelf.swift": {"spacing": 1, "font-size": 1}})
        self.assertEqual(self.run_check(root)[0], 0)

    def test_committed_baseline_matches_the_repository(self):
        out = io.StringIO()
        self.assertEqual(lint.check(ROOT, ROOT / lint.BASELINE, out=out), 0, out.getvalue())


if __name__ == "__main__":
    unittest.main()
