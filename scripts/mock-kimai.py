#!/usr/bin/env python3
"""In-memory Kimai 2.69 lookalike for Chronato's end-to-end test (scripts/e2e.sh).

    scripts/mock-kimai.py --port 8765 [--token e2e-token] [-v]

Binds 127.0.0.1 only. Fictional data. Implements exactly the endpoints Chronato
calls (Sources/ChronatoCore/KimaiClient.swift) with Kimai's default configuration,
checked against Kimai's source (github.com/kimai/kimai, main):

  * Dates in requests: GET filters are strict HTML5 local "YYYY-MM-DDTHH:MM:SS"
    in the API user's time zone (QueryParam DateTime constraint 'Y-m-d\\TH:i:s',
    the current user's DateTimeFactory). Form fields (POST/PATCH begin, end) go
    through DateTimeApiType -> Symfony 6.4 DateTimeToHtml5LocalDateTimeTransformer:
    a lenient prefix match, then `new \\DateTime($value, $viewZone)`, so a trailing
    offset ("...T14:05:00+02:00") wins; without one the view zone applies (POST:
    the new entry's begin, which DefaultMode::create sets in the API user's zone;
    PATCH: the entry's stored zone). Answers: "Y-m-d\\TH:i:sO" in the entry's
    zone, which TimesheetService::fixTimezone sets to the entry user's zone.
  * Tags: the timesheet form's TagsInputType has allow_create = false, so
    TagArrayToStringTransformer silently drops names that are not tags yet.
    GET /api/tags/find?name= is a substring search over visible tags; POST
    /api/tags creates one (UniqueEntity: a taken name is a 400).
  * Rounding (DependencyInjection/Configuration.php defaults begin=1, end=1,
    duration=0, mode default; DefaultRounding): a new entry without begin starts
    at now floored to the minute (DefaultMode::create); whenever an entry with an
    end is saved, begin is floored and end is ceiled to the minute and the
    duration recomputed (Doctrine/TimesheetSubscriber -> DurationCalculator ->
    RoundingService::applyRoundings).
  * active_entries.hard_limit = 1 (default; see __config): creating a running entry
    stops the user's other running ones at "now", in the same request; a refused
    create stops nothing (TimesheetService::saveNewTimesheet -> stopActiveEntries).
  * PATCH /{id}/stop on a stopped entry is a no-op 200 (stopTimesheet).
  * Validation (TimesheetBasicValidator): end before begin, project-specific
    activity of another project, global activity on a project without global
    activities. Form errors as FOSRest renders them: 400 {"code":400,
    "message":"Validation Failed","errors":{...}}; extra fields are rejected.
  * GET /timesheets: begin/end select entries *started* within (TimesheetRepository:
    t.begin >= :begin, t.begin <= :end), size capped at 500, X-Total-Pages etc.
    Unknown tags[] -> 400 "Given tags were not found".
  * /recent: newest entry per (project, activity) by id, then ordered by end DESC
    (MySQL: running entries last); /active: running entries, begin DESC; both
    expanded objects.

Test control (always answered, also while "offline"):
  GET  /__state                  every timesheet, with epoch seconds
  POST /__reset                  back to the seed data
  POST /__offline {"on": bool, "mode": "drop"|"503"}   /api/* drops the connection or answers 503
  POST /__start_external {"project", "activity", "user"=1, "description", "tags"=[], "begin_ago"=seconds}
                                 a timer started in Kimai's web UI (hard limit applies)
  POST /__stop_external {"id"}   stop it in the web UI
  POST /__config {"hard_limit", "view_other", "tracking_mode"}  Kimai's active_entries.hard_limit (reset: 1);
                                 view_other=false: the API user lacks view_other_timesheet, so
                                 GET /api/timesheets ignores `user` (also "all") and answers with
                                 the API user's own entries, no 403 (reset: true);
                                 tracking_mode "punch" (or "duration_fixed_begin"): the API user may not
                                 write times (canUpdateTimesWithAPI() without view_other_timesheet), so
                                 begin/end in POST/PATCH bodies are extra fields (reset: "default")
  POST /__fault {"path", "method"=any, "count"=1, "seconds"=0, "status", "body", "raw",
                 "drop_response"=false, "then_offline"=false}
                                 the next `count` requests to `path`: answered `seconds` later
                                 (a response racing newer ones); with "status", answered with it
                                 and `body` (JSON) or `raw` (HTML, e.g. a captive portal) instead of
                                 being processed; with "drop_response", processed but the answer is
                                 lost (a client timeout), and with "then_offline" the mock goes
                                 offline ("drop") right after
  POST /__timezone {"timezone"}  the API user changes the time zone in their Kimai profile
"""

import argparse
import json
import math
import re
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit
from zoneinfo import ZoneInfo

ROUND_BEGIN_MIN = 1  # Kimai default rounding (Configuration.php)
ROUND_END_MIN = 1
MAX_PAGE_SIZE = 500  # BaseApiController::MAX_PAGE_SIZE
DEFAULT_PAGE_SIZE = 50
RECENT_MAX = 100  # TimesheetController::RECENT_ACTIVITIES_MAX_SIZE
API_USER = 1

USERS = {
    1: {"id": 1, "username": "admin", "alias": None, "timezone": "Europe/Berlin", "language": "en", "visible": True,
        "preferences": [{"name": "first_weekday", "value": "monday"}, {"name": "hourly_rate", "value": "0"}]},
    2: {"id": 2, "username": "Claude", "alias": None, "timezone": "UTC", "language": "en", "visible": True,
        "preferences": [{"name": "first_weekday", "value": "monday"}]},
}
CUSTOMERS = {
    10: {"id": 10, "name": "Northwind Traders", "visible": True, "color": "#2ECC40"},
    7: {"id": 7, "name": "Acme Studio", "visible": True, "color": "#3D9970"},
    12: {"id": 12, "name": "In-house", "visible": True, "color": "#2196F3"},
    99: {"id": 99, "name": "Hidden Corp", "visible": False, "color": "#111111"},
}
PROJECTS = {
    12: {"id": 12, "name": "Ops Dashboard", "customer": 10, "visible": True, "globalActivities": True, "color": "#FF9800"},
    9: {"id": 9, "name": "Consulting", "customer": 7, "visible": True, "globalActivities": True, "color": "#8BC34A"},
    13: {"id": 13, "name": "Internal", "customer": 12, "visible": True, "globalActivities": False, "color": "#2196F3"},
    98: {"id": 98, "name": "Archived", "customer": 10, "visible": False, "globalActivities": True, "color": "#999999"},
}
ACTIVITIES = {
    3: {"id": 3, "name": "Automation", "project": 12, "visible": True, "color": "#39CCCC"},
    5: {"id": 5, "name": "Weekly sync", "project": 12, "visible": True, "color": "#B10DC9"},
    18: {"id": 18, "name": "Internal work", "project": 13, "visible": True, "color": "#2196F3"},
    1: {"id": 1, "name": "Consulting", "project": None, "visible": True, "color": "#8BC34A"},
    21: {"id": 21, "name": "Development", "project": None, "visible": True, "color": "#009688"},
    97: {"id": 97, "name": "Old stuff", "project": None, "visible": False, "color": "#999999"},
}

lock = threading.Lock()
state = {"timesheets": {}, "next_id": 1, "tags": set(), "offline": None, "faults": {}, "hard_limit": 1, "view_other": True,
         "tracking_mode": "default"}


def now():
    return datetime.now(timezone.utc).replace(microsecond=0)


def floor_min(dt, minutes):
    step = minutes * 60
    ts = int(dt.timestamp())
    return dt if minutes <= 0 or ts % step == 0 else datetime.fromtimestamp(ts - ts % step, timezone.utc)


def ceil_min(dt, minutes):
    step = minutes * 60
    ts = int(dt.timestamp())
    return dt if minutes <= 0 or ts % step == 0 else datetime.fromtimestamp(ts - ts % step + step, timezone.utc)


def user_tz(user_id):
    return ZoneInfo(USERS[user_id]["timezone"])


def fmt(dt, tz):
    return None if dt is None else dt.astimezone(tz).strftime("%Y-%m-%dT%H:%M:%S%z")


def parse_local(value, tz):
    """GET filters (DateTime constraint): exactly Y-m-d\\TH:i:s, local time."""
    if not isinstance(value, str):
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=tz).astimezone(timezone.utc)
    except ValueError:
        return None


def parse_form(value, tz):
    """Form fields (DateTimeToHtml5LocalDateTimeTransformer): an offset in the value wins over `tz`."""
    if not isinstance(value, str) or not re.match(r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?", value):
        return None
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    return (parsed if parsed.tzinfo else parsed.replace(tzinfo=tz)).astimezone(timezone.utc)


def save(ts):
    """What Kimai's flush does: duration + rounding once there is an end."""
    if ts["end"] is None:
        ts["duration"] = 0
        return
    ts["begin"] = floor_min(ts["begin"], ROUND_BEGIN_MIN)
    ts["end"] = ceil_min(ts["end"], ROUND_END_MIN)
    ts["duration"] = int((ts["end"] - ts["begin"]).total_seconds()) - ts["break"]


def new_timesheet(user, project, activity, begin, end=None, description=None, tags=()):
    ts = {"id": state["next_id"], "user": user, "project": project, "activity": activity, "begin": begin, "end": end,
          "duration": 0, "break": 0, "description": description, "tags": list(tags), "billable": True, "exported": False,
          "tz": USERS[user]["timezone"]}
    state["next_id"] += 1
    state["tags"].update(tags)
    save(ts)
    state["timesheets"][ts["id"]] = ts
    return ts


def stop(ts, at=None):
    """TimesheetService::stopTimesheet: no-op when stopped; validated."""
    if ts["end"] is not None:
        return None
    end = at or now()
    if ts["begin"] > end:
        return "End date must not be earlier then start date."
    ts["end"] = end
    save(ts)
    return None


def stop_active(user, keep_id):
    """TimesheetService::stopActiveEntries with the configured hard_limit."""
    active = sorted((t for t in state["timesheets"].values() if t["user"] == user and t["end"] is None),
                    key=lambda t: t["begin"])  # repository: begin DESC, then array_reverse
    needs_stop = len(active) - state["hard_limit"]
    for t in active:
        if t["id"] != keep_id and needs_stop > 0:
            error = stop(t)
            if error:
                return error
            needs_stop -= 1
    return None


def seed():
    state["timesheets"] = {}
    state["tags"] = {"ai-claude-code"}
    n = floor_min(now(), 1)
    h = timedelta(hours=1)
    m = timedelta(minutes=1)
    new_timesheet(1, 9, 1, n - 50 * h, n - 50 * h + 45 * m, "Order sync service")
    new_timesheet(1, 12, 3, n - 28 * h, n - 28 * h + 40 * m, "Call tagging automation")
    new_timesheet(1, 12, 5, n - 26 * h, n - 25 * h)
    new_timesheet(2, 13, 18, n - 5 * h, n - 5 * h + 30 * m, "Refactor billing export", ["ai-claude-code"])
    new_timesheet(1, 12, 3, n - 3 * h, n - 3 * h + 95 * m, "Lead routing webhook")
    new_timesheet(1, 98, 1, n - 80 * m, n - 60 * m, "Last task on the archived project")


# MARK: serialization


def customer_json(c):
    return {"id": c["id"], "name": c["name"], "number": None, "comment": None, "visible": c["visible"], "billable": True,
            "currency": "EUR", "color": c["color"], "color-safe": c["color"], "metaFields": [], "teams": []}


def project_json(p, expanded):
    out = {"id": p["id"], "name": p["name"], "parentTitle": CUSTOMERS[p["customer"]]["name"], "orderNumber": None,
           "orderDate": None, "start": None, "end": None, "comment": None, "visible": p["visible"], "billable": True,
           "globalActivities": p["globalActivities"], "number": None, "color": p["color"], "color-safe": p["color"],
           "metaFields": [], "teams": []}
    out["customer"] = customer_json(CUSTOMERS[p["customer"]]) if expanded else p["customer"]
    return out


def activity_json(a, expanded):
    out = {"id": a["id"], "name": a["name"], "comment": None, "visible": a["visible"], "billable": True, "number": None,
           "color": a["color"], "color-safe": a["color"], "metaFields": [], "teams": []}
    if expanded:
        out["project"] = project_json(PROJECTS[a["project"]], True) if a["project"] else None
    else:
        out["parentTitle"] = PROJECTS[a["project"]]["name"] if a["project"] else None
        out["project"] = a["project"]
    return out


def user_json(u, entity=False):
    out = {"id": u["id"], "username": u["username"], "alias": u["alias"], "title": None, "color": None,
           "accountNumber": None, "enabled": True, "systemAccount": False, "initials": u["username"][:2].upper(),
           "timezone": u["timezone"], "language": u["language"], "locale": u["language"]}
    if entity:
        out["preferences"] = u["preferences"]
        out["roles"] = ["ROLE_SUPER_ADMIN"] if u["id"] == 1 else ["ROLE_USER"]
        out["teams"] = []
    return out


def tag_json(name):
    return {"id": sorted(state["tags"]).index(name) + 1, "name": name, "visible": True, "color": None, "color-safe": "#6B7280"}


def timesheet_json(ts, expanded):
    tz = user_tz(ts["user"])
    out = {"id": ts["id"], "begin": fmt(ts["begin"], tz), "end": fmt(ts["end"], tz), "duration": ts["duration"],
           "break": ts["break"], "description": ts["description"], "rate": 0.0, "internalRate": 0.0,
           "exported": ts["exported"], "billable": ts["billable"], "tags": ts["tags"], "metaFields": []}
    if expanded:
        out["user"] = user_json(USERS[ts["user"]])
        out["project"] = project_json(PROJECTS[ts["project"]], True)
        out["activity"] = activity_json(ACTIVITIES[ts["activity"]], True)
    else:
        out["user"], out["project"], out["activity"] = ts["user"], ts["project"], ts["activity"]
    return out


def state_json(ts):
    return {"id": ts["id"], "user": ts["user"], "project": ts["project"], "activity": ts["activity"],
            "description": ts["description"], "tags": ts["tags"], "begin": fmt(ts["begin"], user_tz(ts["user"])),
            "end": fmt(ts["end"], user_tz(ts["user"])), "begin_ts": ts["begin"].timestamp(),
            "end_ts": None if ts["end"] is None else ts["end"].timestamp(), "duration": ts["duration"]}


def validation_failed(root=(), children=None):
    """FOSRest's form error rendering: violations without a matching field land on the root."""
    errors = {"children": {name: ({"errors": msgs} if msgs else {}) for name, msgs in (children or {}).items()}}
    if root:
        errors["errors"] = list(root)
    return 400, {"code": 400, "message": "Validation Failed", "errors": errors}


FORM_FIELDS = {"project", "activity", "begin", "end", "description", "tags", "user", "billable", "exported",
               "fixedRate", "hourlyRate", "internalRate", "rate", "break"}


def apply_form(ts, body, tz):
    """Submit `body` onto `ts` (partial, like $form->submit($data, false)). Returns an error response or None."""
    if not isinstance(body, dict):
        return validation_failed(["This form should not contain extra fields."])
    extra = set(body) - FORM_FIELDS
    if state["tracking_mode"] != "default":
        extra |= {"begin", "end"} & set(body)  # the form has no time fields then
    if extra:
        return validation_failed(["This form should not contain extra fields."])
    children = {}
    if "project" in body:
        p = PROJECTS.get(body["project"]) if isinstance(body["project"], int) else None
        if p is None or not p["visible"]:
            children["project"] = ["This value is not valid."]
        else:
            ts["project"] = p["id"]
    if "activity" in body:
        a = ACTIVITIES.get(body["activity"]) if isinstance(body["activity"], int) else None
        if a is None or not a["visible"]:
            children["activity"] = ["This value is not valid."]
        else:
            ts["activity"] = a["id"]
    for field in ("begin", "end"):
        if field in body:
            if body[field] is None and field == "end":
                ts["end"] = None
                continue
            parsed = parse_form(body[field], tz)
            if parsed is None:
                children[field] = ["This value is not valid."]
            else:
                ts[field] = parsed
    if "description" in body:
        ts["description"] = body["description"] or None  # TextType: "" -> null
    if "tags" in body:
        raw = body["tags"] or ""
        # allow_create = false: names that are not tags yet are dropped, without an error.
        ts["tags"] = [t.strip() for t in str(raw).split(",") if t.strip() in state["tags"]]
    if "user" in body:
        if body["user"] not in USERS:
            children["user"] = ["This value is not valid."]
        else:
            ts["user"] = body["user"]
    if "billable" in body:
        ts["billable"] = bool(body["billable"])
    if children:
        return validation_failed(children=children)
    # TimesheetBasicValidator
    root, children = [], {}
    if ts["project"] is None:
        children["project"] = ["A project needs to be selected."]
    if ts["activity"] is None:
        children["activity"] = ["An activity needs to be selected."]
    if ts["end"] is not None and ts["begin"] > ts["end"]:
        root.append("End date must not be earlier then start date.")
    if ts["project"] is not None and ts["activity"] is not None:
        activity, project = ACTIVITIES[ts["activity"]], PROJECTS[ts["project"]]
        if activity["project"] is not None and activity["project"] != project["id"]:
            children["project"] = ["Project mismatch, project specific activity and timesheet project are different."]
        if activity["project"] is None and not project["globalActivities"]:
            children["activity"] = ["Global activities are forbidden for the selected project."]
    if root or children:
        return validation_failed(root, children)
    return None


# MARK: HTTP


class Handler(BaseHTTPRequestHandler):
    server_version = "mock-kimai/2.69"
    verbose = False
    token = "e2e-token"

    def log_message(self, fmt_, *args):
        if self.verbose:
            sys.stderr.write("mock-kimai: " + fmt_ % args + "\n")

    def send_json(self, status, body, headers=None):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def send_raw(self, status, text):
        data = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        if not raw:
            return {}
        try:
            return json.loads(raw)
        except ValueError:
            return None

    def do_GET(self):
        self.dispatch("GET")

    def do_POST(self):
        self.dispatch("POST")

    def do_PATCH(self):
        self.dispatch("PATCH")

    def dispatch(self, method):
        url = urlsplit(self.path)
        query = parse_qs(url.query, keep_blank_values=True)
        path = url.path.rstrip("/") or "/"
        body = self.read_body() if method in ("POST", "PATCH") else {}
        raw = None
        fault = {}
        with lock:
            if path.startswith("/__"):
                status, payload, headers = self.control(method, path, body)
            else:
                offline = state["offline"]
                if offline == "drop":
                    self.close_connection = True  # no response at all: the client sees a lost connection
                    return
                rule = state["faults"].get(path)
                if rule and rule["count"] > 0 and rule.get("method", method) == method:
                    rule["count"] -= 1
                    fault = rule
                if offline == "503":
                    status, payload, headers = 503, {"code": 503, "message": "Service Unavailable"}, None
                elif "status" in fault:
                    status, payload, headers, raw = fault["status"], fault.get("body"), None, fault.get("raw")
                elif self.headers.get("Authorization") != f"Bearer {self.token}":
                    status, payload, headers = 401, {"code": 401, "message": "Invalid credentials"}, None
                elif body is None:
                    status, payload, headers = 400, {"code": 400, "message": "Invalid JSON body"}, None
                else:
                    status, payload, headers = self.api(method, path, query, body)
                if fault.get("then_offline"):
                    state["offline"] = "drop"
        time.sleep(fault.get("seconds", 0))
        if fault.get("drop_response"):
            self.close_connection = True  # processed, but the answer never arrives
            return
        if raw is not None:
            self.send_raw(status, raw)
        else:
            self.send_json(status, payload, headers)

    # MARK: control

    def control(self, method, path, body):
        if (method, path) == ("GET", "/__state"):
            return 200, {"timesheets": [state_json(t) for t in sorted(state["timesheets"].values(), key=lambda t: t["id"])],
                         "offline": state["offline"]}, None
        if (method, path) == ("POST", "/__reset"):
            seed()
            state["offline"] = None
            state["faults"] = {}
            state["hard_limit"] = 1
            state["view_other"] = True
            state["tracking_mode"] = "default"
            USERS[API_USER]["timezone"] = "Europe/Berlin"
            return 200, {"ok": True}, None
        if (method, path) == ("POST", "/__timezone"):
            # The user changed the time zone in their Kimai profile (travelling).
            USERS[API_USER]["timezone"] = body["timezone"]
            return 200, {"ok": True}, None
        if (method, path) == ("POST", "/__offline"):
            state["offline"] = (body.get("mode") or "drop") if body.get("on") else None
            return 200, {"offline": state["offline"]}, None
        if (method, path) == ("POST", "/__config"):
            state["hard_limit"] = int(body.get("hard_limit", 1))
            state["view_other"] = bool(body.get("view_other", True))
            state["tracking_mode"] = body.get("tracking_mode", "default")
            return 200, {"ok": True}, None
        if (method, path) == ("POST", "/__fault"):
            state["faults"][body["path"]] = dict(body, count=int(body.get("count", 1)))
            return 200, {"ok": True}, None
        if (method, path) == ("POST", "/__start_external"):
            user = body.get("user", 1)
            # The web UI has no seconds; DefaultMode::create floors "now" to the minute.
            begin = floor_min(now() - timedelta(seconds=body.get("begin_ago", 0)), 1)
            ts = new_timesheet(user, body["project"], body["activity"], begin, None, body.get("description"), body.get("tags", ()))
            error = stop_active(user, ts["id"])
            if error:
                del state["timesheets"][ts["id"]]
                return 400, {"error": error}, None
            return 200, state_json(ts), None
        if (method, path) == ("POST", "/__stop_external"):
            ts = state["timesheets"].get(body.get("id"))
            if ts is None:
                return 404, {"error": "no such timesheet"}, None
            error = stop(ts)
            return (400, {"error": error}, None) if error else (200, state_json(ts), None)
        return 404, {"error": "unknown control endpoint"}, None

    # MARK: API

    def api(self, method, path, query, body):
        q = {k: v[-1] for k, v in query.items()}
        me = USERS[API_USER]
        tz = user_tz(API_USER)
        not_found = (404, {"code": 404, "message": "Not Found"}, None)
        visible_only = q.get("visible", "1") == "1"

        if method == "GET":
            if path == "/api/version":
                return 200, {"version": "2.69.0", "versionId": 26900, "copyright": "Kimai mock for Chronato e2e"}, None
            if path == "/api/users/me":
                return 200, user_json(me, entity=True), None
            if path == "/api/users":
                return 200, [user_json(u) for u in USERS.values() if u["visible"] or not visible_only], None
            if path == "/api/customers":
                return 200, [customer_json(c) for c in CUSTOMERS.values() if c["visible"] or not visible_only], None
            if path == "/api/projects":
                return 200, [project_json(p, False) for p in PROJECTS.values() if p["visible"] or not visible_only], None
            if path == "/api/activities":
                return 200, [activity_json(a, False) for a in ACTIVITIES.values() if a["visible"] or not visible_only], None
            if path == "/api/timesheets/active":
                active = [t for t in state["timesheets"].values() if t["user"] == API_USER and t["end"] is None]
                active.sort(key=lambda t: t["begin"], reverse=True)
                return 200, [timesheet_json(t, True) for t in active], None
            if path == "/api/tags/find":
                name = q.get("name")
                return 200, [tag_json(t) for t in sorted(state["tags"]) if isinstance(name, str) and name in t], None
            if path == "/api/timesheets/recent":
                return self.recent(q, tz)
            if path == "/api/timesheets":
                return self.collection(query, q, tz)
            return not_found

        if method == "POST" and path == "/api/timesheets":
            ts = {"id": None, "user": API_USER, "project": None, "activity": None,
                  "begin": floor_min(now(), ROUND_BEGIN_MIN), "end": None, "duration": 0, "break": 0,
                  "description": None, "tags": [], "billable": True, "exported": False,
                  "tz": me["timezone"]}  # the new entry's begin is in the API user's current zone
            error = apply_form(ts, body, tz)
            if error:
                return error[0], error[1], None
            ts["id"] = state["next_id"]
            state["next_id"] += 1
            save(ts)
            state["timesheets"][ts["id"]] = ts
            if ts["end"] is None:
                error = stop_active(ts["user"], ts["id"])
                if error:  # the whole request is rolled back
                    del state["timesheets"][ts["id"]]
                    status, payload = validation_failed([error])
                    payload["message"] = "Cannot stop running timesheet"
                    return status, payload, None
            return 200, timesheet_json(ts, "full" in q), None

        if method == "PATCH" and path.startswith("/api/timesheets/"):
            parts = path.split("/")[3:]
            if not parts[0].isdigit() or len(parts) > 2 or (len(parts) == 2 and parts[1] != "stop"):
                return not_found
            ts = state["timesheets"].get(int(parts[0]))
            if ts is None:
                return not_found
            if len(parts) == 2:
                error = stop(ts)
                if error:
                    status, payload = validation_failed([error])
                    return status, payload, None
                return 200, timesheet_json(ts, False), None
            draft = dict(ts, tags=list(ts["tags"]))
            error = apply_form(draft, body, ZoneInfo(ts["tz"]))  # the zone the entry was stored in
            if error:
                return error[0], error[1], None
            ts.update(draft)
            save(ts)
            return 200, timesheet_json(ts, False), None

        if method == "POST" and path == "/api/tags":
            if not isinstance(body, dict) or set(body) - {"name", "color", "visible"}:
                status, payload = validation_failed(["This form should not contain extra fields."])
                return status, payload, None
            name = str(body.get("name") or "").strip()
            if not name or "," in name or len(name) > 100:
                status, payload = validation_failed(children={"name": ["This value is not valid."]})
                return status, payload, None
            if name in state["tags"]:
                status, payload = validation_failed(children={"name": ["This value is already used."]})
                return status, payload, None
            state["tags"].add(name)
            return 200, tag_json(name), None

        return 405, {"code": 405, "message": "Method Not Allowed"}, None

    def recent(self, q, tz):
        size = q.get("size", "")
        limit = min(int(size), RECENT_MAX) if size.isdigit() else 10
        begin = parse_local(q["begin"], tz) if "begin" in q else None
        latest = {}
        for t in state["timesheets"].values():
            if t["user"] != API_USER or (begin and t["begin"] < begin):
                continue
            key = (t["project"], t["activity"])
            latest[key] = max(latest.get(key, 0), t["id"])
        ids = sorted(latest.values(), reverse=True)[:limit]
        rows = [state["timesheets"][i] for i in ids]
        # ORDER BY t.end DESC; MySQL sorts NULL as the smallest value, so running entries come last.
        rows.sort(key=lambda t: t["end"].timestamp() if t["end"] else -math.inf, reverse=True)
        return 200, [timesheet_json(t, True) for t in rows], None

    def collection(self, query, q, tz):
        rows = list(state["timesheets"].values())
        # TimesheetController::cgetAction reads user/users only if isGranted('view_other_timesheet').
        user = q.get("user") if state["view_other"] else None
        if user == "all":
            pass
        elif user:
            if not user.isdigit():
                return 400, {"code": 400, "message": "Invalid user"}, None
            rows = [t for t in rows if t["user"] == int(user)]
        else:
            rows = [t for t in rows if t["user"] == API_USER]
        for name, op in (("begin", lambda t, d: t["begin"] >= d), ("end", lambda t, d: t["begin"] <= d)):
            if name in q:
                bound = parse_local(q[name], tz)
                if bound is None:
                    return 400, {"code": 400, "message": f'Query parameter "{name}" is invalid'}, None
                rows = [t for t in rows if op(t, bound)]
        tags = query.get("tags[]", [])
        if tags:
            known = [t for t in tags if t in state["tags"]]
            if not known:
                return 400, {"code": 400, "message": "Given tags were not found"}, None
            rows = [t for t in rows if set(t["tags"]) & set(known)]
        order_by = q.get("orderBy", "begin")
        key = {"id": lambda t: t["id"], "begin": lambda t: t["begin"],
               "end": lambda t: t["end"] or datetime.min.replace(tzinfo=timezone.utc)}.get(order_by, lambda t: t["begin"])
        rows.sort(key=key, reverse=q.get("order", "DESC").upper() != "ASC")
        size = int(q["size"]) if q.get("size", "").isdigit() else DEFAULT_PAGE_SIZE
        size = DEFAULT_PAGE_SIZE if size < 1 else min(size, MAX_PAGE_SIZE)
        page = int(q["page"]) if q.get("page", "").isdigit() and int(q["page"]) > 0 else 1
        pages = max(1, math.ceil(len(rows) / size))
        chunk = rows[(page - 1) * size:page * size]
        headers = {"X-Page": str(page), "X-Total-Count": str(len(rows)), "X-Total-Pages": str(pages), "X-Per-Page": str(size)}
        return 200, [timesheet_json(t, q.get("full") in ("1", "true")) for t in chunk], headers


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--token", default="e2e-token")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()
    Handler.token = args.token
    Handler.verbose = args.verbose
    seed()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"mock-kimai listening on http://127.0.0.1:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
