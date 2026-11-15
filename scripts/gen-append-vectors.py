#!/usr/bin/env python3
"""Write conformance/data/append-vectors.json: steps an agent adds to the end of its own open ask.

The cases and their expectations are written by hand in the tables below. The script
only fills in what follows from them: canonical bodies, revision hashes, assigned ids.
It also runs a small reference of the rule over every case and stops (exit 1) when the
reference disagrees with a hand-written expectation, so a typo in the table can't ship.

Usage: python3 scripts/gen-append-vectors.py > conformance/data/append-vectors.json
"""
import copy
import hashlib
import json
import sys

US = '\x1f'

FORMAT = {
    'rule': ('isAppend(base, next): next.steps is longer than base.steps; next.steps[i] equals '
             'base.steps[i] as a JSON value for every i below base.steps.count (ids, sub-steps and '
             'unknown keys included); every top-level key other than steps is present in both or '
             'absent in both, with equal values. JSON value equality ignores key order and white '
             'space. Bodies are compared as parsed JSON, never as decoded models. '
             'appendedSince(history, base): every revision from base + 1 to the newest is isAppend '
             'of the one before it.'),
    'check': ('{name, note, kind: "check", base, next, expect: {append}}. base and next are body '
              'texts, exactly as a Pond could serve them (ids present). append is isAppend(base, next).'),
    'chain': ('{name, note, kind: "chain", revisions: [{rev, prev, at, reason, body, hash}...], accepted, '
              'tamper?: {rev}, expect: {state, problem?, pondAdvances}}. body is the canonical text; '
              'hash is "hook-rev-v1" US rev US prev US at US reason US body (US = U+001F, SHA-256, '
              'lowercase hex). accepted is the revision the owner accepted on this device. tamper '
              'names the revision whose served hash has one hex digit flipped (the hashes after it '
              'are left as computed). state: current (the newest revision is accepted, or every '
              'revision after accepted is an append), pending (a revision after accepted is not an '
              'append), historyChanged (the history check fails; problem as in history-vectors.json). '
              'pondAdvances is the Pond\'s call on its own (untampered) store, made as each revision k '
              'after accepted arrives: k becomes the Pond\'s accepted revision when accepted == k - 1 '
              'and isAppend(k - 1, k). pondAdvances is true when that carries the accepted revision to '
              'the newest, N.'),
    'append': ('{name, note, kind: "append", current, used, rev, request: {note, steps}, expect}. '
               'current is the newest revision\'s body (an object, ids present); used is every step id '
               'of every earlier revision; rev is the revision the append would become; request is '
               'the append call\'s body. Steps without an id get r<rev>-<n>, n counting steps and '
               'sub-steps without an id in document order and skipping any id in use, as an amendment '
               'numbers them. expect is {ok: true, body, added: [{id, path}]} with body the canonical '
               'text of current with the steps appended, and path the 1-based top-level step number '
               'as a string, or {ok: false, status, error, details}. Detail paths name the request '
               '(steps[0] is the request\'s first step), except a limit on the whole result, which '
               'names the result as the post rules do.'),
}


def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(',', ':'), ensure_ascii=False)


def revision_hash(rev, prev, at, reason, body):
    text = US.join(('hook-rev-v1', str(rev), prev, at, reason, body))
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


# ---- the reference rule (a check on the hand-written table, not a source of truth) ----

def is_append(base, nxt):
    bs, ns = base.get('steps'), nxt.get('steps')
    if not isinstance(bs, list) or not isinstance(ns, list) or len(ns) <= len(bs):
        return False
    if any(ns[i] != bs[i] for i in range(len(bs))):
        return False
    keys = (set(base) | set(nxt)) - {'steps'}
    return all((k in base) == (k in nxt) and base.get(k) == nxt.get(k) for k in keys)


def strict(text):
    def pairs(items):
        out = {}
        for key, value in items:
            if key in out:
                raise ValueError('duplicate key')
            out[key] = value
        return out
    return json.loads(text, object_pairs_hook=pairs)


# ---- bodies ----

def base_body():
    return {
        'v': 1,
        'title': 'Rotate the staging deploy key',
        'urgency': 'today',
        'why': 'The old key leaves with the contractor on Friday.',
        'warning': 'Staging deploys stop until the new key is in.',
        'steps': [
            {'id': 's1', 'do': 'Open the deploy settings', 'url': 'https://pond.example.test/settings'},
            {'id': 's2', 'do': 'Make a new key', 'substeps': [
                {'id': 's2.1', 'do': 'Press New key'},
                {'id': 's2.2', 'do': 'Copy it to the Keychain', 'code': 'security add-generic-password -s deploy-key -a staging -w'},
            ]},
            {'id': 's3', 'do': 'Pick when the old key stops', 'question': {
                'prompt': 'When?', 'choices': ['Now', 'Friday']}},
        ],
        'verify': {'do': 'A staging deploy goes through', 'code': 'curl -sI https://pond.example.test/health'},
        'done': ['steps'],
    }


NEW_STEP = {'id': 'r2-1', 'do': 'Delete the old key', 'blocking': True}
SECOND_STEP = {'id': 'r2-2', 'do': 'Tell the team the key changed'}


def appended(body, *steps):
    out = copy.deepcopy(body)
    out['steps'] += [copy.deepcopy(s) for s in steps]
    return out


def edit(body, fn):
    out = copy.deepcopy(body)
    fn(out)
    return out


def text(obj):
    """A body as served: canonical, so each case differs from its base only where it says."""
    return canonical(obj)


def swap_steps(b):
    b['steps'][0], b['steps'][1] = b['steps'][1], b['steps'][0]


def key_order_text():
    """The pure-append result written with keys in another order and spaces in it."""
    b = appended(base_body(), NEW_STEP)
    step0 = b['steps'][0]
    reordered = {
        'done': b['done'],
        'steps': [{'url': step0['url'], 'do': step0['do'], 'id': step0['id']}] + b['steps'][1:],
        'verify': {'code': b['verify']['code'], 'do': b['verify']['do']},
        'why': b['why'], 'warning': b['warning'], 'urgency': b['urgency'], 'title': b['title'], 'v': 1,
    }
    return json.dumps(reordered, ensure_ascii=False, separators=(', ', ': '))


def set_key(path_fn, key, value):
    def fn(b):
        path_fn(b)[key] = value
    return fn


CHECKS = [
    ('pure-append', 'one step added after the last; nothing else changes',
     base_body(), appended(base_body(), NEW_STEP), True),
    ('two-added', 'two steps added at once',
     base_body(), appended(base_body(), NEW_STEP, SECOND_STEP), True),
    ('no-new-steps', 'the same body twice: an append adds at least one step',
     base_body(), base_body(), False),
    ('fewer-steps', 'the last step removed',
     base_body(), edit(base_body(), lambda b: b['steps'].pop()), False),
    ('changed-old-step', "a step's do changed, and a step added",
     base_body(), edit(appended(base_body(), NEW_STEP), set_key(lambda b: b['steps'][0], 'do', 'Open the key settings')), False),
    ('reordered', 'the first two steps swapped, and a step added',
     base_body(), edit(appended(base_body(), NEW_STEP), swap_steps), False),
    ('changed-verify', "verify's do changed, and a step added",
     base_body(), edit(appended(base_body(), NEW_STEP), set_key(lambda b: b['verify'], 'do', 'A production deploy goes through')), False),
    ('changed-why', 'why changed, and a step added',
     base_body(), edit(appended(base_body(), NEW_STEP), set_key(lambda b: b, 'why', 'The key leaked.')), False),
    ('changed-done', 'done changed, and a step added',
     base_body(), edit(appended(base_body(), NEW_STEP), set_key(lambda b: b, 'done', ['steps', 'message'])), False),
    ('changed-warning', 'warning changed, and a step added',
     base_body(), edit(appended(base_body(), NEW_STEP), set_key(lambda b: b, 'warning', 'Production deploys stop too.')), False),
    ('removed-warning', 'warning removed, and a step added: a key absent in one and present in the other',
     base_body(), edit(appended(base_body(), NEW_STEP), lambda b: b.pop('warning')), False),
    ('gains-top-key', 'a top-level key the base has not (links), and a step added',
     base_body(), edit(appended(base_body(), NEW_STEP), set_key(lambda b: b, 'links', [{'label': 'Runbook', 'url': 'https://pond.example.test/runbook'}])), False),
    ('gains-unknown-top-key', 'a top-level key no client knows, and a step added: the rule covers unknown keys',
     base_body(), edit(appended(base_body(), NEW_STEP), set_key(lambda b: b, 'extra', 1)), False),
    ('new-step-first', 'the new step put before the old ones',
     base_body(), edit(base_body(), lambda b: b['steps'].insert(0, copy.deepcopy(NEW_STEP))), False),
    ('new-step-between', 'the new step put between two old ones',
     base_body(), edit(base_body(), lambda b: b['steps'].insert(2, copy.deepcopy(NEW_STEP))), False),
    ('substep-of-old-step-changed', "the new step is fine, but an old sub-step's do changed",
     base_body(), edit(appended(base_body(), NEW_STEP), set_key(lambda b: b['steps'][1]['substeps'][0], 'do', 'Press Add key')), False),
    ('substep-added-to-old-step', 'a sub-step added to an old step, not a step at the end',
     base_body(), edit(base_body(), lambda b: b['steps'][1]['substeps'].append({'id': 'r2-1', 'do': 'Name it'})), False),
    ('old-step-gains-unknown-key', 'an old step gains a key no client knows, and a step added',
     base_body(), edit(appended(base_body(), NEW_STEP), set_key(lambda b: b['steps'][0], 'shell', 'zsh')), False),
    ('old-step-id-changed', "an old step's id changed, and a step added",
     base_body(), edit(appended(base_body(), NEW_STEP), set_key(lambda b: b['steps'][0], 'id', 'open')), False),
]


def chain_bodies(kinds):
    """kinds: 'post', 'append' or 'correct' per revision → [(body, reason)]."""
    out = []
    body = base_body()
    for n, kind in enumerate(kinds, start=1):
        if kind == 'post':
            out.append((copy.deepcopy(body), ''))
        elif kind == 'append':
            body = appended(body, {'id': f'r{n}-1', 'do': f'Added step {n}'})
            out.append((copy.deepcopy(body), 'Two more checks after the answer'))
        elif kind == 'correct':
            body = edit(body, set_key(lambda b: b['steps'][0], 'do', 'Open the key settings'))
            out.append((copy.deepcopy(body), 'The settings page moved'))
    return out


# (name, note, kinds, accepted, tamper rev or None, state, problem or None, pondAdvances)
CHAINS = [
    ('one-append', 'rev 2 adds a step to rev 1, which the owner accepted',
     ['post', 'append'], 1, None, 'current', None, True),
    ('two-appends', 'revs 2 and 3 each add a step; the owner accepted rev 1',
     ['post', 'append', 'append'], 1, None, 'current', None, True),
    ('correction-unaccepted', 'rev 2 changes a step: the owner reviews it',
     ['post', 'correct'], 1, None, 'pending', None, False),
    ('append-on-unaccepted-correction', 'rev 2 corrects, rev 3 appends; the owner accepted only rev 1',
     ['post', 'correct', 'append'], 1, None, 'pending', None, False),
    ('append-after-accepted-correction', 'rev 2 corrects and the owner accepted it; rev 3 appends',
     ['post', 'correct', 'append'], 2, None, 'current', None, True),
    ('append-after-tamper', "rev 2 appends, but its served hash has one digit flipped",
     ['post', 'append'], 1, 2, 'historyChanged', 'badHash:2', True),
]


def build_chain(kinds, tamper):
    revisions, prev = [], ''
    for n, (body, reason) in enumerate(chain_bodies(kinds), start=1):
        at = f'2026-11-14T10:0{n}:00+00:00'
        served = canonical(body)
        digest = revision_hash(n, prev, at, reason, served)
        revisions.append({'rev': n, 'prev': prev, 'at': at, 'reason': reason, 'body': served, 'hash': digest})
        prev = digest
    if tamper is not None:
        rev = revisions[tamper - 1]
        last = rev['hash'][-1]
        rev['hash'] = rev['hash'][:-1] + format((int(last, 16) + 1) % 16, 'x')
    return revisions


def reference_chain(revisions, accepted):
    prev = ''
    for r in revisions:
        if r['prev'] != prev:
            return 'historyChanged', f"badChain:{r['rev']}"
        if revision_hash(r['rev'], r['prev'], r['at'], r['reason'], r['body']) != r['hash']:
            return 'historyChanged', f"badHash:{r['rev']}"
        prev = r['hash']
    bodies = [strict(r['body']) for r in revisions]
    for i in range(accepted, len(bodies)):
        if not is_append(bodies[i - 1], bodies[i]):
            return 'pending', None
    return 'current', None


def pond_advances(kinds, accepted):
    """The Pond's call as each revision arrives: rev k moves its accepted rev to k when
    accepted == k - 1 and isAppend(k - 1, k). True when that carries it to the newest."""
    bodies = [b for b, _ in chain_bodies(kinds)]
    for k in range(accepted + 1, len(bodies) + 1):
        if accepted == k - 1 and is_append(bodies[k - 2], bodies[k - 1]):
            accepted = k
    return accepted == len(bodies)


# ---- append calls ----

def current_rev2():
    """Rev 2's body: a correction removed step s3 (the question), so s3 is used but not current."""
    b = base_body()
    b['steps'].pop()
    return b


USED = ['s1', 's2', 's2.1', 's2.2', 's3']

ERROR = {'ok': False, 'status': 400, 'error': 'invalid steps'}


def twenty_steps():
    b = base_body()
    b['steps'] = [{'id': f's{i}', 'do': f'Step {i}'} for i in range(1, 21)]
    return b


# (name, note, current, used, rev, request, expect: ('ok', ids) or ('error', details))
APPENDS = [
    ('ids-assigned', 'two steps without ids at rev 3 get r3-1 and r3-2',
     current_rev2(), USED, 3,
     {'note': 'Two more checks after the answer', 'steps': [{'do': 'Delete the old key'}, {'do': 'Tell the team'}]},
     ('ok', None)),
    ('ids-given-kept', 'a step that brings an unused id keeps it; the next one is numbered',
     current_rev2(), USED, 3,
     {'note': 'One check and a heads-up', 'steps': [{'id': 'delete-old', 'do': 'Delete the old key'}, {'do': 'Tell the team'}]},
     ('ok', None)),
    ('ids-skip-taken', 'a given id r3-1 is taken, so the step without an id gets r3-2',
     current_rev2(), USED, 3,
     {'note': 'One check and a heads-up', 'steps': [{'id': 'r3-1', 'do': 'Delete the old key'}, {'do': 'Tell the team'}]},
     ('ok', None)),
    ('substep-ids-assigned', "a new step's sub-steps are numbered after it, in document order",
     current_rev2(), USED, 3,
     {'note': 'Clean up the old key', 'steps': [{'do': 'Clean up', 'substeps': [{'do': 'Delete the old key'}, {'do': 'Empty the bin'}]}]},
     ('ok', None)),
    ('id-used-before', 'the step brings id s3, which rev 1 used and the correction removed',
     current_rev2(), USED, 3,
     {'note': 'Bring the question back', 'steps': [{'id': 's3', 'do': 'Pick when the old key stops'}]},
     ('error', ['steps[0].id: used before'])),
    ('over-step-limit', 'the ask has 20 steps; one more makes 21, over the post rule',
     twenty_steps(), [f's{i}' for i in range(1, 21)], 2,
     {'note': 'One more step', 'steps': [{'do': 'Step 21'}]},
     ('error', ['steps: must be a list of 1 to 20 steps'])),
    ('note-too-long', 'the note is 201 characters',
     current_rev2(), USED, 3,
     {'note': 'x' * 201, 'steps': [{'do': 'Delete the old key'}]},
     ('error', ['note: too long'])),
    ('note-at-limit', 'the note is exactly 200 characters',
     current_rev2(), USED, 3,
     {'note': 'x' * 200, 'steps': [{'do': 'Delete the old key'}]},
     ('ok', None)),
    ('secret-in-step', "a new step's code holds something shaped like a token",
     current_rev2(), USED, 3,
     {'note': 'Use the new key', 'steps': [{'do': 'Set the key', 'code': 'export DEPLOY_KEY=ghp_example'}]},
     ('error', ['steps[0].code: secret-like value'])),
]


def assign(current, used, rev, steps):
    """The amendment numbering (r<rev>-<n>) over the new steps; given ids kept."""
    new = copy.deepcopy(steps)
    entries = []
    for step in new:
        entries.append(step)
        entries += step.get('substeps', [])
    taken = set(used) | {e['id'] for e in entries if 'id' in e}
    for step in current['steps']:
        taken.add(step['id'])
        taken |= {s['id'] for s in step.get('substeps', [])}
    n = 0
    for entry in entries:
        if entry.get('id') is not None:
            continue
        while True:
            n += 1
            candidate = f'r{rev}-{n}'
            if candidate not in taken:
                break
        entry['id'] = candidate
        taken.add(candidate)
    return new


def build_append(current, used, rev, request, expect):
    if expect[0] == 'error':
        return dict(ERROR, details=expect[1])
    steps = assign(current, used, rev, request['steps'])
    body = appended(current, *steps)
    start = len(current['steps'])
    added = [{'id': s['id'], 'path': str(start + i + 1)} for i, s in enumerate(steps)]
    if not is_append(current, body):
        raise SystemExit('reference: an ok append is not isAppend')
    return {'ok': True, 'body': canonical(body), 'added': added}


def main():
    cases, problems = [], []
    for name, note, base, nxt, want in CHECKS:
        base_text, next_text = text(base), text(nxt)
        got = is_append(strict(base_text), strict(next_text))
        if got != want:
            problems.append(f'check {name}: table says {want}, reference says {got}')
        cases.append({'name': name, 'note': note, 'kind': 'check', 'base': base_text, 'next': next_text,
                      'expect': {'append': want}})
    order_text = key_order_text()
    if not is_append(strict(text(base_body())), strict(order_text)):
        problems.append('check key-order-differs: reference says False')
    cases.append({'name': 'key-order-differs',
                  'note': 'the pure append written with keys in another order and spaces: JSON values are equal',
                  'kind': 'check', 'base': text(base_body()), 'next': order_text, 'expect': {'append': True}})

    for name, note, kinds, accepted, tamper, state, problem, advances in CHAINS:
        revisions = build_chain(kinds, tamper)
        got_state, got_problem = reference_chain(revisions, accepted)
        got_advances = pond_advances(kinds, accepted)
        if (got_state, got_problem, got_advances) != (state, problem, advances):
            problems.append(f'chain {name}: table says {(state, problem, advances)}, '
                            f'reference says {(got_state, got_problem, got_advances)}')
        case = {'name': name, 'note': note, 'kind': 'chain', 'revisions': revisions, 'accepted': accepted}
        if tamper is not None:
            case['tamper'] = {'rev': tamper}
        expect = {'state': state}
        if problem is not None:
            expect['problem'] = problem
        expect['pondAdvances'] = advances
        case['expect'] = expect
        cases.append(case)

    for name, note, current, used, rev, request, expect in APPENDS:
        cases.append({'name': name, 'note': note, 'kind': 'append', 'current': current, 'used': used,
                      'rev': rev, 'request': request, 'expect': build_append(current, used, rev, request, expect)})

    names = [c['name'] for c in cases]
    if len(set(names)) != len(names):
        problems.append('case names are not unique')
    if problems:
        for p in problems:
            print(p, file=sys.stderr)
        return 1
    doc = {'version': 1, 'source': 'scripts/gen-append-vectors.py', 'format': FORMAT, 'cases': cases}
    sys.stdout.write(json.dumps(doc, indent=1, ensure_ascii=False) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
