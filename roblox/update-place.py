#!/usr/bin/env python3
"""Vymeni zdrojaky skriptu v ulozenem .rbxlx, aniz by sahnul na teren.

    ./update-place.py MountainsSimulator-beskydy.rbxlx [dalsi...]

Place s naimportovanym terenem ma stovky MB voxelu - build.sh ho odmita
prepsat a znovu importovat teren nikdo nechce. Tenhle skript najde skripty
podle jmena (FlightController, ArenaSetup, Mountains, LobbyMenu) a vymeni
jen jejich <ProtectedString name="Source">. Vsechno ostatni - teren,
atributy, cokoliv upraveneho ve Studiu - zustava beze zmeny.

U ArenaSetup zachova arenu: z puvodniho zdrojaku precte DEFAULT_ARENA
a dosadi ji do noveho.

Pred zapisem vznikne zaloha <soubor>.bak. Place nesmi byt zrovna otevreny
ve Studiu (poznas podle <soubor>.lock) - Studio by pri ulozeni zapsalo
svou kopii pres nasi.
"""
import pathlib
import re
import shutil
import sys

HERE = pathlib.Path(__file__).parent
SCRIPTS = {
    "FlightController": "flight-controller.client.lua",
    "ArenaSetup": "arena-setup.server.lua",
    "Mountains": "Mountains.lua",
    "LobbyMenu": "lobby.client.lua",
}
OPEN_TAG = '<ProtectedString name="Source">'
CLOSE_TAG = "</ProtectedString>"


def update(place: pathlib.Path) -> None:
    if place.with_suffix(place.suffix + ".lock").exists():
        sys.exit(f"STOP: {place} je otevreny ve Studiu (existuje .lock). "
                 "Zavri ho, jinak Studio pri ulozeni prepise vymenene skripty.")
    xml = place.read_text()
    changed = []

    for name, fname in SCRIPTS.items():
        marker = f'<string name="Name">{name}</string>'
        i = xml.find(marker)
        if i < 0:
            continue
        j = xml.find(OPEN_TAG, i)
        k = xml.find(CLOSE_TAG, j)
        if j < 0 or k < 0:
            sys.exit(f"{place}: skript {name} nema Source - necekany format")

        src = (HERE / fname).read_text()
        if "]]>" in src:
            sys.exit(f"{fname}: obsahuje ']]>', nejde vlozit do CDATA")

        if name == "ArenaSetup":
            old = xml[j + len(OPEN_TAG):k]
            m = re.search(r'local DEFAULT_ARENA = &quot;(\w+)&quot;|local DEFAULT_ARENA = "(\w+)"', old)
            if m:
                arena = m.group(1) or m.group(2)
                src = re.sub(r'local DEFAULT_ARENA = ".*?"',
                             f'local DEFAULT_ARENA = "{arena}"', src, count=1)

        xml = xml[:j + len(OPEN_TAG)] + "<![CDATA[\n" + src + "]]>" + xml[k:]
        changed.append(name)

    if not changed:
        sys.exit(f"{place}: nenasel jsem zadny znamy skript - nic nemenim")

    backup = place.with_suffix(place.suffix + ".bak")
    shutil.copy2(place, backup)
    place.write_text(xml)
    print(f"{place.name}: vymeneno {', '.join(changed)} (zaloha {backup.name})")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for arg in sys.argv[1:]:
        update(pathlib.Path(arg))
