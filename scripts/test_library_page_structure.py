"""Source guards for the shared iOS Movies/Series page (Build 103).

These check structure that SwiftUI only shows at run time: who owns the page's scroll view, where
the shell header's height is reserved, and how a poster reaches its detail page. They guard the
architecture against regressions; they do not prove taps or layout on a device.

Run: python3 scripts/test_library_page_structure.py
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "iosApp" / "iosApp"


def source(path: str) -> str:
    return (ROOT / path).read_text()


def type_body(text: str, declaration: str) -> str:
    """The source of one top-level type, from its declaration to the next top-level one."""
    start = text.index(declaration)
    following = re.search(r"\n(?:private |fileprivate )?(?:struct|final class|class|enum|extension) ",
                          text[start + len(declaration):])
    end = start + len(declaration) + following.start() if following else len(text)
    return text[start:end]


def brace_block(text: str, open_index: int) -> int:
    """Index just past the brace that closes the one at `open_index`."""
    depth = 0
    for index in range(open_index, len(text)):
        depth += {"{": 1, "}": -1}.get(text[index], 0)
        if depth == 0:
            return index + 1
    return len(text)


def tap_target_labels(text: str, after_name: int) -> list:
    """The label source of a `Button`/`NavigationLink` whose name ends at `after_name`:
    `X(action:) { label }`, `X(value:) { label }` or `X { ... } label: { label }`."""
    cursor = after_name
    arguments = ""
    if text[cursor:cursor + 1] == "(":
        depth = 0
        for index in range(cursor, len(text)):
            depth += {"(": 1, ")": -1}.get(text[index], 0)
            if depth == 0:
                arguments = text[cursor:index + 1]
                cursor = index + 1
                break
    trimmed = text[cursor:].lstrip()
    if not trimmed.startswith("{"):
        return []
    first_open = len(text) - len(trimmed)
    first_close = brace_block(text, first_open)
    rest = text[first_close:].lstrip()
    if rest.startswith("label:"):
        label_open = text.index("{", first_close)
        return [text[label_open:brace_block(text, label_open)]]
    # `Button("Title") { action }` puts the action, not a label, in the trailing closure.
    if arguments.startswith('("') or arguments.startswith("(role"):
        return []
    return [text[first_open:first_close]]


LIBRARIES = "iosApp/iosApp/Screens/Browse/LibrariesTabView.swift"
BROWSE = "iosApp/iosApp/Screens/Browse/BrowseView.swift"
COLLECTIONS = "iosApp/iosApp/Screens/Collections/CollectionsView.swift"
IPTV = "iosApp/iosApp/Kyro/IPTVVOD/KyroIPTVLibraryContent.swift"


class LibraryPageStructureTests(unittest.TestCase):
    # Navigation

    def test_no_media_card_is_wrapped_in_another_tap_target(self):
        """MediaCard is a Button. Inside a NavigationLink or Button label it swallows the tap
        (Build 102) or, with hit testing off, nothing receives it (Builds 100 and 101)."""
        offenders = []
        for path in APP.rglob("*.swift"):
            text = path.read_text()
            for match in re.finditer(r"\b(NavigationLink|Button)\b", text):
                for label in tap_target_labels(text, match.end()):
                    if "MediaCard(" in label:
                        line = text[:match.start()].count("\n") + 1
                        offenders.append(f"{path.relative_to(ROOT)}:{line}")
        self.assertEqual(offenders, [])

    def test_iptv_cards_open_the_shared_detail_card_through_the_router(self):
        card = type_body(source(IPTV), "struct KyroIPTVPosterCard")
        self.assertNotIn("NavigationLink", card)
        self.assertIn("router.presentIPTVDetail(KyroIPTVDetailRequest(item: item, providerName: providerName))", card)
        sheet = type_body(source("iosApp/iosApp/ContentView.swift"), "private struct ItemDetailSheet")
        self.assertIn("else if let iptv = presentation.iptv", sheet)
        self.assertIn("KyroIPTVVODDetailView(", sheet)
        self.assertIn("onClose: router.dismissItemDetail", sheet)

    def test_silo_cards_keep_router_navigation(self):
        self.assertIn("router.navigate(to: .itemDetail(browseItem: $0, libraryId: libraryId))", source(BROWSE))
        self.assertIn("router.navigate(to: .libraryCollection(", source(COLLECTIONS))

    # Scroll container ownership

    def test_only_the_shared_container_reads_the_page_controls(self):
        reader = "@Environment(\\.libraryPageScrollControls)"
        readers = {
            str(path.relative_to(ROOT)): path.read_text().count(reader)
            for path in APP.rglob("*.swift")
            if reader in path.read_text()
        }
        self.assertEqual(readers, {LIBRARIES: 2}, "LibraryPageScrollContainer and LibraryPageStatus only")

    def test_every_movies_and_series_tab_scrolls_in_the_shared_container(self):
        tabs = [
            (BROWSE, "struct LibraryRecommendedView"),
            (COLLECTIONS, "struct LibraryCollectionsView"),
            (IPTV, "struct KyroIPTVLibraryContent"),
            (IPTV, "private struct KyroIPTVRecommendedView"),
            (IPTV, "private struct KyroIPTVLibraryGridView"),
            (IPTV, "private struct KyroIPTVCollectionsView"),
        ]
        for path, declaration in tabs:
            with self.subTest(declaration):
                body = type_body(source(path), declaration)
                self.assertIn("LibraryPageScrollContainer", body)
                self.assertNotIn("ScrollView {", body)
                self.assertNotIn("ScrollView(.vertical", body)
        browse = type_body(source(BROWSE), "struct BrowseView")
        self.assertEqual(browse.count("LibraryPageScrollContainer {"), 2, "loaded and empty grids")
        self.assertIn("LibraryPageStatus {", browse, "the error state keeps the controls")

    def test_only_the_shell_header_is_pinned_and_its_height_is_reserved_once(self):
        page = type_body(source(LIBRARIES), "struct LibrariesTabView")
        self.assertEqual(page.count(".safeAreaPadding(.top, hostedHeader?.runway ?? 0)"), 1)
        self.assertNotIn(".safeAreaInset(edge: .top", page)
        self.assertNotIn("Color.clear.frame(height", page)
        self.assertNotIn("PageChromeGlass", page)
        self.assertNotIn("pageChromeBacking", page)
        header = source("iosApp/iosApp/Kyro/Shell/KyroAppHeader.swift")
        self.assertNotIn("headerDrawsGlass", header, "the header draws its glass on Movies and Series too")

    # Sources popup

    def test_sources_picker_exposes_selected_state(self):
        label = type_body(source(LIBRARIES), "private struct LibraryPickerRowLabel")
        self.assertIn('Image(systemName: "checkmark")', label)
        self.assertIn("isSelected ? Color.siloOnSurface.opacity(0.24)", label)
        self.assertIn('accessibilityValue(isSelected ? "Selected" : "Not selected")', label)


if __name__ == "__main__":
    unittest.main()
