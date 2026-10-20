"""Render SOLIS Play Store graphics from screenshots/out with headless Chrome. Run: python marketing/play-store/graphics/render.py"""
import pathlib, subprocess, html
from PIL import Image

ROOT = pathlib.Path(r"C:\Users\varsh\solis_mobile")
SHOTS = ROOT / "screenshots" / "out"
OUT = ROOT / "marketing" / "play-store" / "graphics"
import tempfile
TMP = pathlib.Path(tempfile.gettempdir()) / "solis_play_render"
CHROME = r"C:\Program Files\Google\Chrome\Application\chrome.exe"
OUT.mkdir(parents=True, exist_ok=True)
(OUT / "phone").mkdir(exist_ok=True)
TMP.mkdir(exist_ok=True)

FONTS = '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=Manrope:wght@700;800&display=block">'

SCREENS = [
    ("16_consent", "Consent comes first", "The patient hears a short script in English or Spanish, then agrees out loud or signs on the phone."),
    ("07_recording", "Listens to the visit", "Tells the doctor's voice from the patient's. On-device or cloud engine, your choice."),
    ("08_note", "The note writes itself", "A concise SOAP note for your review. Sources show the words behind each section."),
    ("10_claim_checks", "Codes from the patient's words", "Symptoms stay symptoms until you confirm a diagnosis. One tap to confirm."),
    ("09_claim_uncertain", "Checks before you send", "Against the official CMS code sets for the date of service, each with its fix."),
    ("19_claim_why", "A Why on every check", "The rule in plain English, what it means on this claim and its official citation."),
    ("03_scan_review", "Scan the cards", "Insurance card and driver's license read on the phone. Photos deleted after reading."),
    ("24_billing", "Claims in one list", "See what needs a signature, what needs a fix and what is ready to send."),
]

SLUGS = ["consent", "recording", "note", "diagnosis-codes", "claim-checks", "why", "scan-cards", "billing"]

PHONE_CSS = """
*{margin:0;padding:0;box-sizing:border-box}
html,body{width:1080px;height:1920px;overflow:hidden}
body{background:#FDE2F6;font-family:Inter,'Segoe UI',sans-serif;position:relative}
.band{position:absolute;left:0;top:0;width:1080px;height:360px;background:#980F86;color:#fff;padding:64px 80px 0}
.band h1{font-family:Manrope,'Segoe UI',sans-serif;font-weight:800;font-size:60px;letter-spacing:-1.3px;line-height:1.08}
.band p{margin-top:22px;font-size:34px;line-height:1.38;color:#FDE2F6;font-weight:500}
.frame{position:absolute;left:50%;top:410px;transform:translateX(-50%);width:{W}px;height:{H}px;border-radius:44px;overflow:hidden;
  background:#fff;box-shadow:0 30px 70px rgba(78,0,68,.22),0 0 0 10px #4E0044}
.frame img{width:100%;height:100%;display:block}
"""


def chrome(html_path, png_path, w, h):
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                    f"--window-size={w+40},{h+120}", "--virtual-time-budget=8000", "--default-background-color=00000000",
                    f"--screenshot={png_path}", html_path.as_uri()], check=True, capture_output=True)
    im = Image.open(png_path)
    assert im.size[0] >= w and im.size[1] >= h, im.size
    im = im.crop((0, 0, w, h))
    bg = Image.new("RGB", im.size, (253, 226, 246))
    bg.paste(im.convert("RGBA"), mask=im.convert("RGBA").split()[3])
    bg.save(png_path, optimize=True)


def phones():
    # screenshot area: from 410 to 1920-60 -> 1450 px tall, keep 824x1830 aspect
    H = 1450
    W = round(H * 824 / 1830)
    css = PHONE_CSS.replace("{W}", str(W)).replace("{H}", str(H))
    for i, (name, title, sub) in enumerate(SCREENS, 1):
        src = (SHOTS / f"{name}.png").as_uri()
        doc = f"""<!doctype html><html><head><meta charset="utf-8">{FONTS}<style>{css}</style></head><body>
<div class="band"><h1>{html.escape(title)}</h1><p>{html.escape(sub)}</p></div>
<div class="frame"><img src="{src}"></div></body></html>"""
        p = TMP / f"phone_{i}.html"
        p.write_text(doc, encoding="utf-8")
        chrome(p, OUT / "phone" / f"{i:02d}_{SLUGS[i-1]}.png", 1080, 1920)
        print("phone", i, name)


MARK = """<svg viewBox="0 0 1024 1024" width="{s}" height="{s}"><rect width="1024" height="1024" rx="235.52" fill="#FFFFFF"/>
<path fill="#980F86" d="M358.4 486.4A235.52 235.52 0 0 1 829.44 486.4ZM665.6 537.6A235.52 235.52 0 0 1 194.56 537.6Z"/></svg>"""
LETTERS = """<svg viewBox="312 72 373 96" width="{w}" height="{h}"><path fill="#FFFFFF" fill-rule="evenodd" d="M340.32 128.64A28.32 28.32 0 0 1 340.32 72L340.32 89.28A11.04 11.04 0 0 0 340.32 111.36ZM354.01 111.36A28.32 28.32 0 0 1 354.01 168L354.01 150.72A11.04 11.04 0 0 0 354.01 128.64ZM340.32 72H382.33V89.28H340.32ZM340.32 111.36H354.01V128.64H340.32ZM312 150.72H354.01V168H312ZM397.69 120A48 48 0 1 1 493.69 120A48 48 0 1 1 397.69 120ZM414.97 120A30.72 30.72 0 1 0 476.41 120A30.72 30.72 0 1 0 414.97 120ZM509.05 72H526.33V168H509.05ZM509.05 150.72H566.65V168H509.05ZM582.01 72H599.29V168H582.01ZM642.97 128.64A28.32 28.32 0 0 1 642.97 72L642.97 89.28A11.04 11.04 0 0 0 642.97 111.36ZM656.661 111.36A28.32 28.32 0 0 1 656.661 168L656.661 150.72A11.04 11.04 0 0 0 656.661 128.64ZM642.97 72H684.981V89.28H642.97ZM642.97 111.36H656.661V128.64H642.97ZM614.65 150.72H656.661V168H614.65Z"/></svg>"""


def feature():
    css = """*{margin:0;padding:0;box-sizing:border-box}
html,body{width:1024px;height:500px;overflow:hidden}
body{background:#980F86;font-family:Inter,'Segoe UI',sans-serif;color:#fff;position:relative}
.glow{position:absolute;right:-160px;top:-160px;width:620px;height:620px;border-radius:50%;background:radial-gradient(circle,rgba(229,163,232,.35),rgba(229,163,232,0) 70%)}
.wrap{position:absolute;left:96px;top:0;height:500px;display:flex;flex-direction:column;justify-content:center;width:560px}
.brand{display:flex;align-items:center;gap:26px}
h1{margin-top:44px;font-family:Manrope,'Segoe UI',sans-serif;font-weight:800;font-size:46px;line-height:1.12;letter-spacing:-1px}
p{margin-top:20px;font-size:23px;line-height:1.4;color:#FDE2F6;font-weight:500}
.shot{position:absolute;right:84px;top:56px;width:216px;height:480px;border-radius:26px;overflow:hidden;box-shadow:0 0 0 7px #4E0044,0 24px 50px rgba(0,0,0,.25)}
.shot img{width:100%;display:block}"""
    src = (SHOTS / "08_note.png").as_uri()
    doc = f"""<!doctype html><html><head><meta charset="utf-8">{FONTS}<style>{css}</style></head><body>
<div class="glow"></div>
<div class="wrap"><div class="brand">{MARK.format(s=84)}{LETTERS.format(w=327, h=84)}</div>
<h1>The visit, the note and the claim, on your phone.</h1>
<p>Documentation and billing for US practices.</p></div>
<div class="shot"><img src="{src}"></div></body></html>"""
    p = TMP / "feature.html"
    p.write_text(doc, encoding="utf-8")
    chrome(p, OUT / "feature-graphic-1024x500.png", 1024, 500)
    print("feature")


if __name__ == "__main__":
    feature()
    phones()
