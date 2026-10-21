#!/usr/bin/env bash
# Paso 32 (entrega): publica en GitHub Pages (rama gh-pages de itinerarios-docs) los reportes
# JaCoCo de los 4 backends y la galeria de capturas del ultimo Selenium. Sitio estatico y
# gratuito (seccion 91); sin secretos: solo HTML de cobertura y PNG de la UI con datos de prueba.
# Uso, desde itinerarios-infrastructure, despues de run-cloud-tests.sh:
#   bash aws/publish-reports.sh
set -euo pipefail

MVN="${MVN:-mvn}"
GH="${GH_CLI:-gh}"
OWNER=FernandoMartinez018
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
SHOTS="$HERE/../e2e-tests/target/e2e-screenshots"
SUREFIRE="$HERE/../e2e-tests/target/surefire-reports"
SITE="$(mktemp -d)"

[ -n "$(ls "$SHOTS"/*.png 2>/dev/null)" ] || { echo "No hay capturas en $SHOTS: correr Selenium primero"; exit 1; }

for r in airport-service itinerary-service notification gateway; do
  (cd "$ROOT/itinerarios-$r" && "$MVN" -B -ntp -q clean verify)
  mkdir -p "$SITE/jacoco/$r" && cp -r "$ROOT/itinerarios-$r/target/site/jacoco/." "$SITE/jacoco/$r/"
done
mkdir -p "$SITE/selenium" && cp "$SHOTS"/*.png "$SITE/selenium/"

python - "$SITE" "$SUREFIRE" <<'EOF'
import csv, glob, html, os, sys, datetime
import xml.etree.ElementTree as ET
site, surefire = sys.argv[1], sys.argv[2]

def coverage(svc):  # % de lineas desde jacoco.csv
    miss = cov = 0
    for row in csv.DictReader(open(os.path.join(site, "jacoco", svc, "jacoco.csv"))):
        miss += int(row["LINE_MISSED"]); cov += int(row["LINE_COVERED"])
    return round(100 * cov / max(miss + cov, 1))

tests = fails = 0
for x in glob.glob(os.path.join(surefire, "TEST-*.xml")):
    r = ET.parse(x).getroot()
    tests += int(r.get("tests", 0)); fails += int(r.get("failures", 0)) + int(r.get("errors", 0))

rows = "".join(f'<li><a href="jacoco/{s}/index.html">{s}</a> &mdash; {coverage(s)}% de lineas</li>'
               for s in ["airport-service", "itinerary-service", "notification", "gateway"])
shots = sorted(os.listdir(os.path.join(site, "selenium")))
gallery = "".join(f'<figure><a href="selenium/{f}"><img src="selenium/{f}" alt="{html.escape(f)}"></a>'
                  f'<figcaption>{html.escape(f[:-4])}</figcaption></figure>' for f in shots)
when = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
open(os.path.join(site, "index.html"), "w", encoding="utf-8").write(f"""<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Itinerarios - Reportes</title>
<style>body{{font-family:system-ui,sans-serif;max-width:1100px;margin:auto;padding:16px;color:#1f2937}}
figure{{display:inline-block;width:320px;margin:8px;vertical-align:top}}img{{width:100%;border:1px solid #ccc;border-radius:6px}}
figcaption{{font-size:.9em;text-align:center}}</style></head><body>
<h1>Sistema de Itinerarios Personales &mdash; reportes de pruebas</h1>
<p>Generado: {when}</p>
<h2>Cobertura JaCoCo (mvn verify)</h2><ul>{rows}</ul>
<h2>Selenium E2E: {tests} pruebas, {fails} fallas</h2>
<p>Flujo completo contra el despliegue en AWS (frontend en ECS &rarr; Gateway &rarr; servicios).</p>
{gallery}
</body></html>""")
print(f"index.html: {len(shots)} capturas, selenium {tests}/{fails}")
EOF

# Publica como unico commit en gh-pages (historial irrelevante para un reporte regenerable).
cd "$SITE" && touch .nojekyll && git init -q -b gh-pages && git add -A \
  && git -c user.name="$(git -C "$ROOT/itinerarios-docs" config user.name)" \
         -c user.email="$(git -C "$ROOT/itinerarios-docs" config user.email)" commit -qm "Reportes de pruebas (paso 32)" \
  && git push -qf "https://github.com/$OWNER/itinerarios-docs.git" gh-pages
"$GH" api "repos/$OWNER/itinerarios-docs/pages" >/dev/null 2>&1 \
  || "$GH" api -X POST "repos/$OWNER/itinerarios-docs/pages" -f "source[branch]=gh-pages" -f "source[path]=/" >/dev/null
echo "Reportes: https://${OWNER,,}.github.io/itinerarios-docs/"
