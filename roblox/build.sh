#!/bin/bash
# Sestavi .rbxlx z lua zdrojaku v teto slozce.
# Zdrojem pravdy jsou .lua soubory -- po uprave spust ./build.sh znovu.
#
#   ./build.sh            # arena beskydy (testovaci vyrez) + lobby
#   ./build.sh everest    # arena everest + lobby
#
# Mountains.lua je generovany: terrain-fetch --emit-lua roblox/Mountains.lua
set -e
cd "$(dirname "$0")"

ARENA="${1:-beskydy}"
if ! grep -q "\[\"$ARENA\"\]" Mountains.lua; then
	echo "neznama arena '$ARENA'; Mountains.lua zna:" >&2
	grep -o '\["[a-z]*"\]' Mountains.lua | tr -d '["]' | sed 's/^/  /' >&2
	exit 1
fi

# hlavicka a paticka jednoho .rbxlx
open_place() {
	cat <<'XML'
<roblox xmlns:xmime="http://schemas.microsoft.com/2003/10/Serialization/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">
XML
}

# script_item <class> <referent> <name> <soubor>
script_item() {
	printf '\t\t<Item class="%s" referent="%s">\n\t\t\t<Properties>\n\t\t\t\t<string name="Name">%s</string>\n\t\t\t\t<ProtectedString name="Source"><![CDATA[\n' "$1" "$2" "$3"
	cat "$4"
	printf ']]></ProtectedString>\n\t\t\t</Properties>\n\t\t</Item>\n'
}

# service <class> <referent>
open_service() {
	printf '\t<Item class="%s" referent="%s">\n\t\t<Properties>\n\t\t\t<string name="Name">%s</string>\n\t\t</Properties>\n' "$1" "$2" "$1"
}
close_service() { printf '\t</Item>\n'; }

# --- arena ---------------------------------------------------------------
ARENA_SRC=$(mktemp)
sed "s/^local DEFAULT_ARENA = .*/local DEFAULT_ARENA = \"$ARENA\"/" arena-setup.server.lua > "$ARENA_SRC"

OUT="MountainsSimulator-$ARENA.rbxlx"

# Pojistka: place s naimportovanym terenem ma megabajty. Prepsat ho buildem
# by znamenalo prijit o rucni praci v Terrain Editoru.
if [ -f "$OUT" ] && [ "$(wc -c < "$OUT" | tr -d ' ')" -gt 1000000 ]; then
	echo "STOP: $OUT vypada, ze uz obsahuje naimportovany teren." >&2
	echo "Prejmenuj/zalohuj ho, nebo ho smaz, pokud chces stavet znovu." >&2
	exit 1
fi

{
open_place
printf '\t<Item class="Workspace" referent="RBXWS">\n\t\t<Properties>\n\t\t\t<string name="Name">Workspace</string>\n\t\t\t<bool name="StreamingEnabled">true</bool>\n\t\t</Properties>\n'
cat <<'XML'
		<Item class="SpawnLocation" referent="RBXSPAWN">
			<Properties>
				<string name="Name">SpawnLocation</string>
				<bool name="Anchored">true</bool>
				<bool name="CanCollide">false</bool>
				<float name="Transparency">1</float>
				<int name="Duration">0</int>
				<CoordinateFrame name="CFrame">
					<X>0</X><Y>900</Y><Z>0</Z>
					<R00>1</R00><R01>0</R01><R02>0</R02>
					<R10>0</R10><R11>1</R11><R12>0</R12>
					<R20>0</R20><R21>0</R21><R22>1</R22>
				</CoordinateFrame>
				<Vector3 name="size"><X>12</X><Y>1</Y><Z>12</Z></Vector3>
			</Properties>
		</Item>
XML
close_service
open_service ReplicatedStorage RBXRS
script_item ModuleScript RBXMTN Mountains Mountains.lua
close_service
open_service ServerScriptService RBXSSS
script_item Script RBXARENA ArenaSetup "$ARENA_SRC"
close_service
cat <<'XML'
	<Item class="StarterPlayer" referent="RBXSP">
		<Properties>
			<string name="Name">StarterPlayer</string>
		</Properties>
		<Item class="StarterPlayerScripts" referent="RBXSPS">
			<Properties>
				<string name="Name">StarterPlayerScripts</string>
			</Properties>
XML
script_item LocalScript RBXFLY FlightController flight-controller.client.lua
printf '\t\t</Item>\n\t</Item>\n</roblox>\n'
} > "$OUT"
rm -f "$ARENA_SRC"

# --- lobby ---------------------------------------------------------------
LOBBY="MountainsLobby.rbxlx"
{
open_place
open_service Workspace RBXWS2
cat <<'XML'
		<Item class="SpawnLocation" referent="RBXSPAWN2">
			<Properties>
				<string name="Name">SpawnLocation</string>
				<bool name="Anchored">true</bool>
				<int name="Duration">0</int>
				<CoordinateFrame name="CFrame">
					<X>0</X><Y>4</Y><Z>0</Z>
					<R00>1</R00><R01>0</R01><R02>0</R02>
					<R10>0</R10><R11>1</R11><R12>0</R12>
					<R20>0</R20><R21>0</R21><R22>1</R22>
				</CoordinateFrame>
				<Vector3 name="size"><X>40</X><Y>1</Y><Z>40</Z></Vector3>
			</Properties>
		</Item>
XML
close_service
open_service ReplicatedStorage RBXRS2
script_item ModuleScript RBXMTN2 Mountains Mountains.lua
close_service
cat <<'XML'
	<Item class="StarterPlayer" referent="RBXSP2">
		<Properties>
			<string name="Name">StarterPlayer</string>
		</Properties>
		<Item class="StarterPlayerScripts" referent="RBXSPS2">
			<Properties>
				<string name="Name">StarterPlayerScripts</string>
			</Properties>
XML
script_item LocalScript RBXLOBBY LobbyMenu lobby.client.lua
printf '\t\t</Item>\n\t</Item>\n</roblox>\n'
} > "$LOBBY"

for f in "$OUT" "$LOBBY"; do
	xmllint --noout "$f"
	echo "OK: $f ($(wc -c < "$f" | tr -d ' ') bytes)"
done
echo "arena: $ARENA"
