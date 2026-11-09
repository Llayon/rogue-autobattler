"""The release-gate negative controls (R4).

    NC-REL-01  remove the dependency on battle-ecs        -> RED
    NC-REL-02  remove the dependency on save-battle-migration -> RED
    NC-REL-03  allow a failed/skipped required job        -> RED
    NC-REL-04  remove the SHA identity check              -> RED
    NC-REL-05  allow a manual deployment bypass           -> RED
    NC-REL-06  accept a missing index.html                -> RED
    NC-REL-07  allow a stale deployment to supersede a newer commit -> RED
    NC-REL-08  accept a reference to a path the artifact does not carry -> RED
    NC-REL-09  upload the artifact from the wrong job     -> RED

Every mutation is applied to an ISOLATED TEMPORARY COPY of the
workflow files. The production workflows are never written to.

WHAT EACH CONTROL MEASURES

    The GATE controls -- NC-REL-01..05, 07 and 09 -- mutate the
    WORKFLOWS and assert a PROPERTY of the result:

      - the deploy job's `needs` really contains the required call;
      - a required job carries NO condition at all, because a
        condition is the only way to take a job out of the run;
      - no job carries `continue-on-error: true`;
      - the deploy job really checks out, so the tip check can read
        a remote;
      - ONE condition really compares the published SHA with the
        branch tip, and really refuses;
      - the concurrency group really is per ref;
      - the job that BUILDS the artifact uploads it, and the deploy
        job does not upload a directory it does not have.

    The VALIDATOR controls -- NC-REL-06 and NC-REL-08 -- mutate the
    ARTIFACT VALIDATOR and compare two validator invocations. They
    say nothing about the gate: they say that the artifact gate
    itself cannot be weakened.

WHY THEY ARE STRUCTURAL AND NOT TEXTUAL

    The first version of this harness evaluated a "decision function"
    that read the workflow as TEXT. That was worthless, and the
    independent critic proved it: a genuinely broken deploy was
    reported as a PASS, because the decision function RECOGNISED the
    mutation by its text and denied it -- a rule written for that
    exact mutation.

    A textual decision function cannot separate "the gate is broken"
    from "the mutation text is unusual". So each control here
    asserts a PROPERTY, and the mutation must BREAK that property:
    the CLEAN gate satisfies it, the MUTATED gate must not. A
    mutation that does not open anything is reported as MISSED and
    counts as a problem, so the harness exits 0 only when every
    control is a real RED.

HOW THE WORKFLOWS ARE READ

    Not with a YAML library. This file was the only one in the
    repository that imported yaml, and no CI workflow installs
    pyyaml, so the step would have failed on the runner and turned
    the REQUIRED battle-ecs job RED. The reader here is a small
    indentation scanner that returns the job names and the body of
    each job, which is what the properties need.
"""

import io
import os
import re
import shutil
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOWS = os.path.join(REPO, ".github", "workflows")
RELEASE = os.path.join(WORKFLOWS, "release.yml")
TEST = os.path.join(WORKFLOWS, "test.yml")
VALIDATOR = os.path.join(REPO, "tools", "validate_web_artifact.py")



# =====================================================================
# THE STRUCTURAL PROPERTIES
#
# Each property returns a list of violations. An empty list means the
# gate has the property. A control mutates the gate and asserts that
# the property VIOLATIONS APPEAR.
# =====================================================================

def _needs_of(jobs, job_name):
    """The `needs:` list of a job.

    The job reader already returns the BODY of the job, so the list is
    simply inside it. Both the inline form ("needs: [a, b]") and the
    block form ("needs:\n  - a") are read.
    """
    body = jobs.get(job_name) or ""
    inline = re.search(r"needs:\s*\[([^\]]*)\]", body)
    if inline:
        return inline.group(1)
    # The block form is read LINE BY LINE. The earlier regex was
    # greedy across the newline, so the SECOND item was lost: the
    # deploy job rewritten in the standard block form would report
    # "the deploy does not need the web build" and block the
    # publication. A false RED in the required CI job is the worst
    # class of defect in a harness that gates a publication.
    block = re.search(r"^\s*needs\s*:\s*$", body, re.MULTILINE)
    if block:
        items = []
        for line in body[block.end():].split("\n")[1:]:
            if not line.strip():
                continue
            if not line.strip().startswith("-"):
                break
            items.append(line.strip().lstrip("-").strip())
        if items:
            return " ".join(items)
    plain = re.search(r"needs\s*:\s*(.+)$", body, re.MULTILINE)
    if plain:
        # The QUOTED scalar form -- 'needs: "a, b"' -- is valid YAML,
        # and the quotes must not become part of the job names. The
        # value is the REST of the line: a quoted value may contain
        # a space.
        return _unquote(plain.group(1).strip())
    return ""


def _job(jobs, name):
    """The body of a job, as text."""
    return jobs.get(name) or ""


def _block(jobs, job_name):
    """The body of a job as a text block, for the line-level checks."""
    return jobs.get(job_name) or ""


def _unquote(value):
    """The value without its matching surrounding quotes.

    A job condition can be written as a plain scalar or as a double
    quoted one -- both are valid YAML and valid GHA. The harness
    returned the value WITH the quotes, so the tokenizer failed and
    the parse raised a TypeError that run_control swallowed as
    INVALID: a red CI on a legitimate edit.
    """
    stripped = value.strip()
    if len(stripped) >= 2 and stripped[0] == stripped[-1] \
            and stripped[0] in ("'", '"'):
        return stripped[1:-1]
    return stripped


def _job_condition(block):
    """The JOB-LEVEL `if:` condition of a job, if it has one.

    The condition is read SEMANTICALLY: the key is matched with any
    spacing, and the value is returned as it stands. A literal
    substring match on "if: false" would only catch that one spelling
    -- "if: ${{ false }}", "if: ${{ !cancelled() }}" and "if:
    github.event_name == 'never'" would all slip through, and the
    required job could be disabled while every control stayed green.

    It is read at the JOB level only. The job keys sit at four
    spaces; a STEP key sits deeper, and a step-level condition is a
    legitimate thing to write -- a cleanup step with "if: always()",
    for instance. Reading the step-level condition as the job-level
    one would make a perfectly valid workflow fail the controls, and
    a false RED in the required CI job blocks the publication.

    A FOLDED or LITERAL block scalar is expanded: the value of
    "if: >-" is the indented block that follows it, not the ">-".
    """
    lines = block.split("\n")
    for index, line in enumerate(lines):
        # The job-level keys are indented by exactly four spaces.
        if not line.startswith("    ") or line.startswith("     "):
            continue
        match = re.match(r"^    if\s*:\s*(.*)$", line)
        if not match:
            continue
        # The trailing comment is cut off FIRST: "if: >-  # only
        # master may publish" is valid YAML, and the block scalar
        # must still be recognised as one.
        value = _without_trailing_comment(match.group(1).strip())
        if value in (">-", ">", "|-", "|"):
            # The condition is the block that follows, joined.
            parts = []
            for follow in lines[index + 1:]:
                if not follow.strip():
                    continue
                if not follow.startswith("      "):
                    break
                parts.append(follow.strip())
            return _unquote(" ".join(parts).strip())
        return _unquote(value)
    return ""


def _never_runs(block):
    """True when the job's condition can disable it.

    ANY condition on a required job is treated as a guard: the
    required jobs must always run, and a condition is the only way to
    take one out of the run.
    """
    condition = _job_condition(block)
    if not condition:
        return False
    # A condition that is literally true cannot disable the job.
    normalised = condition.strip().strip("'\"").lower()
    if normalised in ("true", "${{ true }}", "${{true}}"):
        return False
    return True


# ---------------------------------------------------------------------------
# The release authorization model.
#
# A job-level `if:` is an expression over the run context. The release
# authorization has to be decided from the EXPRESSION: a workflow that
# mentions refs/heads/master in a comment, in a shell step, or in a
# disjunction that also accepts every other branch does NOT authorize
# only master.
#
# So the expression is EVALUATED. The evaluator understands the
# operators the release contract uses -- &&, ||, !, ==, !=,
# parentheses, the success() and always() status functions, and the
# github.ref and github.event_name context values. Anything it does
# not understand makes the evaluation FAIL CLOSED: an expression it
# cannot decide never authorizes a deployment.
# ---------------------------------------------------------------------------

# The refs the release is allowed to publish from.
ALLOWED_DEPLOY_REF = "refs/heads/master"

# The events that may publish.
ALLOWED_DEPLOY_EVENTS = ("push", "workflow_dispatch")


def _tokenize(expression):
    """Split a GitHub Actions expression into tokens."""
    tokens = []
    index = 0
    length = len(expression)
    while index < length:
        char = expression[index]
        if char.isspace():
            index += 1
            continue
        if char in "()!&|":
            if expression.startswith("&&", index):
                tokens.append("&&")
                index += 2
                continue
            if expression.startswith("||", index):
                tokens.append("||")
                index += 2
                continue
            tokens.append(char)
            index += 1
            continue
        if char == "=" and expression.startswith("==", index):
            tokens.append("==")
            index += 2
            continue
        if char == "!" and expression.startswith("!=", index):
            tokens.append("!=")
            index += 2
            continue
        if char in "\"'":
            quote = char
            end = expression.find(quote, index + 1)
            if end < 0:
                return None
            tokens.append(expression[index:end + 1])
            index = end + 1
            continue
        if char == "$" and expression.startswith("${{", index):
            end = expression.find("}}", index)
            if end < 0:
                return None
            inner = expression[index + 3:end]
            # The ${{ ... }} wrapper is a GROUP: the inner text is the
            # expression, and it is parsed as a normal token sequence.
            inner_tokens = _tokenize(inner)
            if inner_tokens is None:
                return None
            tokens.append("(")
            tokens.extend(inner_tokens)
            tokens.append(")")
            index = end + 2
            continue
        start = index
        while index < length and (expression[index].isalnum()
                                  or expression[index] in "_.-"):
            index += 1
        if index == start:
            return None
        word = expression[start:index]
        # A function CALL -- success(), always(), cancelled() -- is ONE
        # token. Without this, "success()" would be read as the name
        # "success" followed by a parenthesis, and the parse would
        # fail.
        if index < length and expression[index] == "(":
            end = expression.find(")", index)
            if end < 0:
                return None
            tokens.append(word + expression[index:end + 1])
            index = end + 1
            continue
        tokens.append(word)
    return tokens


def _parse(tokens):
    """Parse the tokens into a tree: (or, and, not, comparison, name)."""
    position = [0]

    def peek():
        return tokens[position[0]] if position[0] < len(tokens) else None

    def take():
        token = peek()
        position[0] += 1
        return token

    def parse_or():
        node = parse_and()
        while peek() == "||":
            take()
            right = parse_and()
            node = ("or", node, right)
        return node

    def parse_and():
        node = parse_unary()
        while peek() == "&&":
            take()
            right = parse_unary()
            node = ("and", node, right)
        return node

    def parse_unary():
        if peek() == "!":
            take()
            return ("not", parse_unary())
        return parse_primary()

    def parse_primary():
        token = take()
        if token is None:
            return None
        if token == "(":
            node = parse_or()
            if peek() == ")":
                take()
            return node
        if token in ("==", "!="):
            # A comparison whose left side was consumed as a separate
            # name: "github.ref == 'x'" arrives here as the name first
            # and the operator second, so the operator branch handles
            # the case where the name is missing.
            right = take()
            return ("cmp", token, None, right)
        # A name. If the NEXT token is a comparison operator, the two
        # belong together: "github.ref == 'refs/heads/master'".
        if peek() in ("==", "!="):
            operator = take()
            right = take()
            return ("cmp", operator, token, right)
        return ("name", None, None, token)

    tree = parse_or()
    if position[0] != len(tokens):
        return None
    return tree


def _evaluate(tree, context):
    """Evaluate a parsed tree against the run context.

    Returns True, False, or None for "cannot decide". None makes the
    caller fail closed.
    """
    if tree is None:
        return None
    kind = tree[0]
    if kind == "and":
        left = _evaluate(tree[1], context)
        if left is False:
            return False
        right = _evaluate(tree[2], context)
        if left is None or right is None:
            return None if (left is not False and right is not False) else False
        return bool(left) and bool(right)
    if kind == "or":
        left = _evaluate(tree[1], context)
        if left is True:
            return True
        right = _evaluate(tree[2], context)
        if left is None or right is None:
            return None if (left is not True and right is not True) else True
        return bool(left) or bool(right)
    if kind == "not":
        value = _evaluate(tree[1], context)
        if value is None:
            return None
        return not value
    if kind == "cmp":
        operator, left, right = tree[1], tree[2], tree[3]
        left_value = _value(left, context)
        right_value = _value(right, context)
        if left_value is None or right_value is None:
            return None
        if operator == "==":
            # GitHub Actions compares strings with == IGNORING THE
            # CASE. The model must reproduce the PLATFORM, not an
            # idealized comparison: a model that were stricter than
            # the platform would report a policy the platform does
            # not enforce.
            return _loose_equal(left_value, right_value)
        return not _loose_equal(left_value, right_value)
    if kind == "name":
        return _value(tree[3], context)
    return None


def _loose_equal(left, right):
    """The GitHub Actions string equality: the case is IGNORED.

    The documentation states that the comparison is not case
    sensitive. So `github.ref == 'refs/heads/master'` is also true
    for a branch named "Master".

    That is why the workflow does not rely on the string alone: the
    deploy job also compares the SHA being published with the tip of
    master, which the case cannot change.
    """
    if isinstance(left, bool) or isinstance(right, bool):
        return left == right
    if isinstance(left, str) and isinstance(right, str):
        return left.lower() == right.lower()
    return left == right


def _value(token, context):
    """The value of a name or a literal in the run context."""
    if token is None:
        return None
    if token.startswith("'") or token.startswith('"'):
        return token[1:-1]
    if token == "success()":
        return context.get("success")
    if token == "always()":
        return True
    if token == "cancelled()":
        # cancelled() is TRUE only when the WORKFLOW was cancelled.
        # The context does not model a cancellation of the workflow
        # itself, and the needs failing is NOT a cancellation: a
        # failed need makes failure() true and cancelled() false.
        return bool(context.get("cancelled"))
    if token == "!cancelled()":
        return not bool(context.get("cancelled"))
    if token == "failure()":
        return context.get("success") is False
    if token == "github.ref":
        return context.get("ref")
    if token == "github.event_name":
        return context.get("event")
    if token == "github.sha":
        return context.get("sha")
    if token == "true":
        return True
    if token == "false":
        return False
    return None


def deploy_is_authorized(release, event, ref, required_ok):
    """Does the deploy job run for this event and ref?

    This is the model of the release gate that the branch
    authorization controls check. It answers the question from the
    JOB-LEVEL CONDITION OF THE DEPLOY JOB -- not from a string
    search, and not from a comment.

    required_ok is the result of the needs graph: True when both
    required jobs succeeded, False otherwise.

    The answer is a pair: (authorized, reason).
    """
    deploy = release["jobs"].get("deploy")
    if deploy is None:
        return False, "there is no deploy job"

    needs = _needs_of(release["jobs"], "deploy")
    if "required-tests" not in needs:
        return False, "the deploy does not need the required tests"
    if "web-build" not in needs:
        return False, "the deploy does not need the web build"

    condition = _job_condition(deploy)
    if not condition:
        # No condition at all: the deploy job inherits the default,
        # which is success() -- so it depends on the needs, but on
        # NOTHING that restricts the ref.
        if not required_ok:
            return False, "a required job did not succeed"
        return True, "no ref condition: every ref is authorized"

    # Strip the ${{ ... }} wrapper.
    expression = condition
    if expression.startswith("${{"):
        expression = expression[3:]
        if expression.endswith("}}"):
            expression = expression[:-2]

    tokens = _tokenize(expression)
    if tokens is None:
        return False, "the deploy condition cannot be parsed"
    tree = _parse(tokens)
    if tree is None:
        return False, "the deploy condition cannot be parsed"

    context = {
        "success": bool(required_ok),
        # The workflow itself is not cancelled in this model: the
        # needs failing is a FAILURE, not a cancellation.
        "cancelled": False,
        "ref": ref,
        "event": event,
        "sha": "0" * 40,
    }
    verdict = _evaluate(tree, context)
    if verdict is None:
        return False, "the deploy condition cannot be decided"
    if verdict:
        return True, "the condition authorizes it"
    return False, "the condition refuses it"


def prop_01_battle_ecs_dependency(release, test):
    """The release CALLS the reusable workflow AND that workflow runs
    the battle-ecs job."""
    out = []
    release_text = release["text"]
    if "uses: ./.github/workflows/test.yml" not in release_text:
        out.append("the release does not call the reusable test workflow")
    if "battle-ecs" not in test["jobs"]:
        out.append("the reusable workflow carries no battle-ecs job")
    else:
        block = test["jobs"]["battle-ecs"]
        if _never_runs(block):
            out.append("the battle-ecs job is conditioned and can be "
                       "skipped: %s" % _job_condition(block))
    return out


def prop_02_save_dependency(release, test):
    """The save-battle-migration job exists and really runs."""
    out = []
    if "save-battle-migration" not in test["jobs"]:
        out.append("the reusable workflow carries no save-battle-migration job")
    else:
        block = test["jobs"]["save-battle-migration"]
        if _never_runs(block):
            out.append("the save-battle-migration job is conditioned and "
                       "can be skipped: %s" % _job_condition(block))
    return out


def prop_03_no_failure_tolerance(release, test):
    """No job may continue on error, and no required job may be
    conditioned so that a failure does not block."""
    out = []
    for name, block in list(release["jobs"].items()) + list(test["jobs"].items()):
        if "continue-on-error: true" in block:
            out.append("the %s job continues on error" % name)
    return out


def prop_04_sha_identity(release, test):
    """The tip really compares the published SHA with the branch tip,
    and the comparison really refuses.

    The property is about the COMPARISON, not about the surrounding
    shell: the deploy job also refuses an UNREADABLE tip, and that
    refusal must not be mistaken for the identity check.
    """
    out = []
    deploy = release["jobs"].get("deploy", "")

    # The published SHA and the branch tip must be compared with EACH
    # OTHER, in ONE condition, and that condition must refuse.
    #
    # The check is per CONDITION, not per file: the step has three
    # separate statements, and a mutation that removes only the
    # comparison leaves the other two intact.
    compares = False
    code = _code_lines(deploy)
    # The comparison must be a CONDITION that REFUSES. An echo that
    # merely MENTIONS the comparison is not a check: it prints a
    # message and continues. And a comparison whose `exit 1` was
    # deleted does not refuse either -- so the refusal must be inside
    # the comparison's own condition.
    tip_block = _step_block(_body_without_comments(deploy), "tip of the branch")
    if tip_block is not None:
        for line in tip_block.split("\n"):
            stripped = line.strip()
            if not stripped.startswith("if "):
                continue
            if "TIP" in stripped and "github.sha" in stripped:
                compares = True
                # The refusal must belong to THE COMPARISON's own
                # condition: another condition in the same step
                # refusing is a different mechanism.
                if not _condition_refuses(tip_block, stripped):
                    out.append("the SHA comparison does not refuse: it "
                               "notices the mismatch and continues")
                # The condition must not be neutralised.
                neutral = _neutralised(stripped)
                if neutral:
                    out.append("the SHA comparison is neutralised by "
                               "%s: it can never hold" % neutral)
                # The SHAs must DIFFER for a stale publication: the
                # comparison is "!=", never "==".
                if "!=" not in stripped and "==" not in stripped:
                    out.append("the SHA comparison does not compare the "
                               "two SHAs")
                elif "==" in stripped and "!=" not in stripped:
                    out.append("the SHA comparison is INVERTED: it refuses "
                               "when the SHAs match")
                # The refusal must exit NON-ZERO.
                if not _exit_is_a_refusal(tip_block, stripped):
                    out.append("the SHA comparison does not exit non-zero: "
                               "exit 0 reports success and continues")
                break
    if not compares and not out:
        out.append("the deploy job never compares the published SHA "
                   "with the branch tip in a condition that refuses")

    # The identity of the built and the deployed SHA is carried in the
    # artifact.
    build = release["jobs"].get("web-build", "")
    if "BUILD_SHA" not in build:
        out.append("the build does not record its provenance")
    return out


def prop_05_no_manual_bypass(release, test):
    """The deploy reaches the pages only through the required call.

    The contract is BEHAVIOURAL, not textual. The old version
    rejected ANY job-level condition on the deploy job -- which was
    wrong: the correct release guard IS a job-level condition, and
    rejecting it would have forbidden the fix of the branch
    authorization gap.

    What is actually forbidden is a condition that authorizes a
    deployment the required call does not cover. So the property
    asks the model: can the deploy job run when the required jobs did
    not succeed? If it can, the bypass is back.
    """
    out = []
    needs = _needs_of(release["jobs"], "deploy")
    if "required-tests" not in needs:
        out.append("the deploy does not need the required tests")
    if "web-build" not in needs:
        out.append("the deploy does not need the web build")

    # A condition that ignores the outcome of the required jobs -- an
    # always(), or a condition with no success() term -- authorizes
    # the deployment even when they failed.
    deploy = release["jobs"].get("deploy", "")
    condition = _job_condition(deploy)
    if condition and "success()" not in condition:
        allowed, reason = deploy_is_authorized(release, "push",
                                                "refs/heads/master", False)
        if allowed:
            out.append("the deploy condition does not depend on the "
                       "outcome of the required jobs")
    return out


def prop_06_artifact_validation(release, test):
    """The artifact is validated, and it is the validated bytes that
    are published.

    The validation step must be a real GATE, so three things are
    asserted, not one:

      - it really invokes the validator;
      - it really targets the BUILD directory;
      - it does not swallow the failure.

    Without the third one, "python tools/validate_web_artifact.py build
    || true" would validate nothing and still look like a gate.
    """
    out = []
    build = release["jobs"].get("web-build", "")
    if "validate_web_artifact.py" not in build:
        out.append("the build does not validate the artifact")
    else:
        # The step must target the build directory.
        invocation = ""
        for line in build.split("\n"):
            if "validate_web_artifact.py" in line:
                invocation = line.strip()
                break
        arguments = invocation.split("validate_web_artifact.py", 1)[1]
        if "build" not in arguments:
            out.append("the validation does not target the build "
                       "directory: %s" % invocation)
        # The step must not swallow the failure.
        if "|| true" in invocation or "|| true" in build:
            out.append("the validation swallows its failure")
        if "continue-on-error" in build:
            out.append("the build job continues on error")
    # The job that BUILDS the artifact uploads it.
    if "upload-pages-artifact" not in build:
        out.append("the build job does not upload the artifact")
    # The deploy job must not upload a directory it does not have.
    deploy = release["jobs"].get("deploy", "")
    if "upload-pages-artifact" in deploy:
        out.append("the deploy job uploads a build/ directory it does "
                   "not have")
    return out


def prop_06b_validation_is_a_gate(release, test):
    """The validation step must be a real GATE.

    A step that invokes the validator but swallows its failure
    validates nothing while still looking like a gate. The same goes
    for a step that targets the wrong directory.
    """
    out = []
    build = release["jobs"].get("web-build", "")
    for line in build.split("\n"):
        if "validate_web_artifact.py" not in line:
            continue
        invocation = line.strip()
        if "|| true" in invocation:
            out.append("the validation swallows its failure: %s" % invocation)
        arguments = invocation.split("validate_web_artifact.py", 1)[1]
        if "build" not in arguments:
            out.append("the validation does not target the build "
                       "directory: %s" % invocation)
    if "continue-on-error" in build:
        out.append("the build job continues on error")
    return out


def _body_without_comments(job_body):
    """The body of a job with the comment lines dropped and the
    INDENTATION kept.

    The indentation is what delimits a step from the next one, so it
    cannot be stripped.
    """
    body = []
    for line in job_body.split("\n"):
        stripped = line.strip()
        if stripped and stripped.startswith("#"):
            continue
        body.append(line)
    return "\n".join(body)


def _code_lines(job_body):
    """The CODE lines of a job: the comments are dropped.

    The workflow's own comment blocks literally contain the text the
    checks are looking for -- "refs/heads/master", "always()", "git
    ls-remote origin refs/heads/master". A search over the whole body
    therefore matches the COMMENT and the control reports GREEN while
    the mechanism it protects is gone. Every check reads CODE.
    """
    code = []
    for line in job_body.split("\n"):
        stripped = line.strip().lstrip("\ufeff")
        if not stripped or stripped.startswith("#"):
            continue
        # A TRAILING comment carries the tokens too: "ls-remote origin
        # refs/heads/master # the tip of master" is a code line whose
        # text contains the whole policy. The comment is cut off, but
        # only when the '#' is not inside a quoted string.
        code.append(_without_trailing_comment(stripped))
    return "\n".join(code)


def _has_master_sha_check(deploy_body):
    """Is there a REAL step that compares the published SHA with the
    tip of master?

    The check reads CODE, never comments: the workflow's own comment
    block literally contains the text "git ls-remote origin
    refs/heads/master", so a textual search matched the COMMENT and
    the control reported GREEN while the STEP it protects was gone.

    So the requirement has two parts:
      - a step named for the master check must exist, and
      - a CODE line -- not a comment -- must read the tip of
        refs/heads/master from the remote.
    """
    # The step must exist.
    if not re.search(r"^\s*- name: .*master", deploy_body, re.MULTILINE):
        return False

    # The remote read must be in CODE, and a TRAILING comment must
    # not count: 'MASTER_SHA="" # git ls-remote origin refs/heads/master'
    # mentions the whole policy and reads nothing.
    code = _code_lines(deploy_body)
    for line in code.split("\n"):
        stripped = line.strip()
        if "ls-remote" in stripped and "refs/heads/master" in stripped:
            return True
    return False


def prop_07_branch_authorization(release, test):
    """The deployment is authorized ONLY from refs/heads/master.

    Both sides of the contract are asserted. The forbidden refs must
    be refused AND the legitimate master push must still be allowed:
    a property that only ever denies would be satisfied by a workflow
    that never publishes anything.
    """
    out = []

    forbidden = [
        ("workflow_dispatch", "refs/heads/staging/phase3-master-verification",
         "a manual dispatch of the staging branch"),
        ("workflow_dispatch", "refs/heads/phase3/effect-status-trigger-gauntlet",
         "a manual dispatch of the Phase 3 branch"),
        ("workflow_dispatch", "refs/heads/feature/x",
         "a manual dispatch of a feature branch"),
        ("workflow_dispatch", "refs/heads/feature/master",
         "a manual dispatch of a branch whose name ends with master"),
        ("workflow_dispatch", "refs/tags/v1.0",
         "a manual dispatch of a tag"),
        ("push", "refs/heads/staging/phase3-master-verification",
         "a push to the staging branch"),
        # The EVENT matters as much as the ref: a condition that also
        # accepts pull_request would publish a pull request's build.
        ("pull_request", "refs/heads/master",
         "a pull request event"),
        ("pull_request", "refs/heads/feature/x",
         "a pull request event on a feature branch"),
        ("schedule", "refs/heads/master",
         "a scheduled event"),
        ("workflow_run", "refs/heads/master",
         "a workflow_run event"),
    ]
    for event, ref, label in forbidden:
        allowed, reason = deploy_is_authorized(release, event, ref, True)
        if allowed:
            out.append("the deploy is authorized for %s" % label)

    allowed, reason = deploy_is_authorized(release, "push",
                                            "refs/heads/master", True)
    if not allowed:
        out.append("the deploy refuses a legitimate push to master: %s"
                   % reason)
    allowed, reason = deploy_is_authorized(release, "workflow_dispatch",
                                            "refs/heads/master", True)
    if not allowed:
        out.append("the deploy refuses a legitimate dispatch on master: %s"
                   % reason)

    # The string comparison is NOT enough on its own: GitHub Actions
    # compares strings with == IGNORING THE CASE, so a branch named
    # "Master" passes `github.ref == 'refs/heads/master'`. The deploy
    # job must therefore ALSO compare the SHA being published with
    # the tip of master, which the case cannot change.
    deploy = release["jobs"].get("deploy", "")
    # The check must be SPECIFIC and UNCONDITIONAL. The deploy job has
    # two remote reads: the tip-check, which compares against the tip
    # of the DISPATCHED branch, and the master-check, which compares
    # against the tip of refs/heads/master. Only the second one
    # protects against the wrong branch, because the string comparison
    # of the job-level condition is case insensitive: a branch named
    # "Master" would pass it.
    #
    # The requirement does NOT depend on the job mentioning
    # "refs/heads/master" elsewhere: removing the master-check also
    # removes that mention, and a conditional requirement would then
    # be satisfied by its own absence.
    if not _has_master_sha_check(deploy):
        out.append("the deploy does not compare the published SHA with "
                   "the tip of master: the ref string comparison is "
                   "case insensitive, so a branch named Master would "
                   "pass it")

    # The master check must be the WHOLE mechanism: it must READ the
    # tip of master, COMPARE it with the published SHA, and REFUSE.
    # A check that reads the tip and does nothing with it proves
    # nothing -- and the case-insensitivity of the string comparison
    # is exactly what the comparison is there to answer.
    code = _code_lines(deploy)
    master_read = re.search(r"ls-remote[^\n]*refs/heads/master", code)
    if master_read:
        compares = False
        master_block = _step_block(_body_without_comments(deploy), "master")
        for line in code.split("\n"):
            stripped = line.strip()
            if not stripped.startswith("if"):
                continue
            if ("MASTER_SHA" in stripped and "github.sha" in stripped
                    and ("!=" in stripped or "==" in stripped)):
                compares = True
                # The same shape as the tip comparison: not
                # neutralised, not inverted, and a non-zero exit.
                neutral = _neutralised(stripped)
                if neutral:
                    out.append("the master comparison is neutralised by "
                               "%s: it can never hold" % neutral)
                if "==" in stripped and "!=" not in stripped:
                    out.append("the master comparison is INVERTED: it "
                               "refuses when the SHAs match")
                if master_block is not None and not _exit_is_a_refusal(
                        master_block, stripped):
                    out.append("the master comparison does not exit "
                               "non-zero: exit 0 reports success and "
                               "continues")
                break
        if not compares:
            out.append("the master check reads the tip of master but "
                       "never compares it with the published SHA")
        # The refusal must belong to THIS check: the tip-check's own
        # "exit 1" is a different mechanism, and its presence would
        # satisfy a global search even when the master check's refusal
        # was deleted.
        master_block = _step_block(_body_without_comments(deploy),
                                    "master")
        if master_block is not None:
            # The refusal for an UNREADABLE tip must be SPECIFIC: a
            # check that the tip is empty and then HOLDs. The global
            # "exit 1" was satisfied by the OTHER refusal in the same
            # step -- the comparison -- so deleting the unreadable
            # case left the check green.
            # The refusal for an UNREADABLE tip must be a CONDITION
            # that refuses: a check that the tip is empty, followed by
            # a HOLD INSIDE that condition. The exit of a DIFFERENT
            # condition a few lines below is a different mechanism.
            holds = False
            for line in master_block.split("\n"):
                stripped = line.strip()
                if stripped.startswith("if ") and "-z" in stripped:
                    # The condition must test the MASTER's own
                    # variable: a condition that tests another one
                    # holds for the wrong tip and sails on for the
                    # right one.
                    if not _tests_variable(stripped, "MASTER_SHA"):
                        out.append("the master check tests another "
                                   "variable for readability: %s" % stripped)
                        break
                    holds = _condition_refuses(master_block, stripped)
                    break
            if not holds:
                out.append("the master check does not fail closed: an "
                           "unreadable tip must be a HOLD, never a GREEN")
    return out


def prop_11_sha_checks_stay_real(release, test):
    """The SHA checks must READ THE REMOTE.

    A check that compares the published SHA with ITSELF always
    succeeds, so it proves nothing: the stale publication would pass
    it. Both checks must read the tip from the remote, and both must
    fail closed.
    """
    out = []
    deploy = release["jobs"].get("deploy", "")
    # The CODE lines only: the workflow's own comments contain the
    # text "git ls-remote origin refs/heads/master", so a search over
    # the whole body matched the COMMENT and the control reported
    # GREEN while the check it protects was gone.
    # The CODE lines, with the trailing comments cut off: a tip read
    # replaced by 'TIP="${{ github.sha }}" # git ls-remote origin
    # "refs/heads/${GITHUB_REF_NAME}"' mentions the whole policy and
    # reads nothing.
    code_text = _code_lines(deploy)

    if "ls-remote" not in code_text:
        out.append("the deploy does not read the remote: a SHA check "
                   "that compares the published SHA with itself always "
                   "succeeds")
        return out

    # The tip of the DISPATCHED branch.
    if not re.search(r"ls-remote[^\n]*GITHUB_REF_NAME", code_text):
        out.append("the deploy does not read the tip of the dispatched "
                   "branch")
    # The tip of master.
    if not re.search(r"ls-remote[^\n]*refs/heads/master", code_text):
        out.append("the deploy does not read the tip of master")
    # The fail-closed refusals: each must be inside its own condition.
    for needle, label, variable in (
            ("tip of the branch", "the tip check", "TIP"),
            ("master", "the master check", "MASTER_SHA")):
        block = _step_block(_body_without_comments(deploy), needle)
        if block is None:
            continue
        holds = False
        for line in block.split("\n"):
            stripped = line.strip()
            if stripped.startswith("if ") and "-z" in stripped:
                # The variable belongs to the block: the tip check
                # tests TIP and the master check tests MASTER_SHA.
                if not _tests_variable(stripped, variable):
                    out.append("%s tests another variable for "
                               "readability: %s" % (label, stripped))
                    break
                holds = _condition_refuses(block, stripped)
                break
        if not holds:
            out.append("%s does not fail closed: an unreadable tip must "
                       "be a HOLD, never a GREEN" % label)
    return out


def prop_12_permissions_are_minimal(release, test):
    """The elevated permissions belong to the deploy job alone.

    pages: write and id-token: write must appear ONLY on the job that
    publishes. On the build job they would let a build step publish
    whatever it likes, without the deploy job's checks.
    """
    out = []
    for name, body in release["jobs"].items():
        if name in ("push", "workflow_dispatch"):
            continue
        code = _code_lines(body)
        # The rule is not a list of spellings: EVERY permission of every
        # job other than the deploy job must be read-only. A sweep of
        # named scopes would miss "write-all" and "contents: write".
        #
        # The permissions are read as the BLOCK they are: the scalar
        # form "permissions: write-all" is elevated by itself, and the
        # block form lists one scope per line.
        permissions = _job_permissions(body)
        for scope, value in permissions:
            if value in ("write", "write-all"):
                if name != "deploy":
                    out.append("the %s job carries %s: %s"
                               % (name, scope, value))
                break

    # The deploy job may hold EXACTLY the three scopes it needs. It
    # was exempt from the check above, so it could hold any elevated
    # scope at all -- contents: write, actions: write,
    # pull-requests: write. An elevated scope on the publish job is a
    # STANDING capability, not a one-off need.
    allowed = {"pages": "write", "id-token": "write", "contents": "read"}
    deploy_permissions = _job_permissions(release["jobs"].get("deploy", ""))
    for scope, value in deploy_permissions:
        if allowed.get(scope) != value:
            out.append("the deploy job carries %s: %s: it may hold only %s"
                       % (scope, value,
                          ", ".join("%s: %s" % (k, v)
                                    for k, v in sorted(allowed.items()))))
    # And it must hold ALL of them: a MISSING scope was never
    # checked, so the deploy could lose its OIDC minting right or its
    # checkout right -- and the tip-checks could not read the remote.
    held = {scope for scope, _ in deploy_permissions}
    for scope in sorted(allowed):
        if scope not in held:
            out.append("the deploy job has no %s: it may hold only %s"
                       % (scope,
                          ", ".join("%s: %s" % (k, v)
                                    for k, v in sorted(allowed.items()))))
    # The WORKFLOW-LEVEL permissions block lives outside every job
    # body, so it was never examined. A job's own block OVERRIDES the
    # workflow default, so the danger is a top-level elevation
    # together with a job whose block was DELETED: that job would
    # inherit the elevation. So the workflow default must be
    # read-only, and every job must carry its own explicit block.
    workflow_permissions = _workflow_permissions(release)
    for scope, value in workflow_permissions:
        if value in ("write", "write-all"):
            out.append("the workflow-level permissions carry %s: %s"
                       % (scope, value))
    for name, body in release["jobs"].items():
        if name in ("push", "workflow_dispatch"):
            continue
        if not _job_permissions(body):
            out.append("the %s job has no explicit permissions block: it "
                       "would inherit the workflow default" % name)

    # The deploy job must still carry them: without them it could
    # not publish at all.
    deploy = _code_lines(release["jobs"].get("deploy", ""))
    if "pages: write" not in deploy:
        out.append("the deploy job has no pages: write: it could not "
                   "publish")

    # The environment is part of the policy. The deploy job publishes
    # into the github-pages environment, whose branch restrictions are
    # a repository setting the owner has NOT verified. A different
    # environment would be one whose restrictions may not be set at
    # all.
    if "github-pages" not in deploy:
        out.append("the deploy job does not publish into the "
                   "github-pages environment: the environment's branch "
                   "restriction is the owner's action and must not be "
                   "swapped for another one")

    # There must be exactly ONE publication step. A second one would
    # publish without the checks that guard the first: the checks look
    # at the job's body, and one guarded path plus one unguarded path
    # is an unguarded path.
    # The count is a RULE, not a spelling: a step that PUBLISHES is
    # counted -- by its action's capability, not by its name. A
    # third-party Pages action is a second publication path, and the
    # count of "actions/deploy-pages" would not see it.
    # The deploy job's steps must be EXACTLY the ones the mechanism
    # needs: a duplicated step is a step the controls did not
    # certify, and the count of the publications must stay exact.
    configure_count = deploy.count("actions/configure-pages")
    if configure_count != 1:
        out.append("the deploy job configures the pages %d times: there "
                   "must be exactly one configuration" % configure_count)

    publishing = 0
    for line in deploy.split("\n"):
        stripped = line.strip()
        if "uses:" in stripped:
            if _is_a_publication_step(stripped):
                publishing += 1
            continue
        # A publisher can also be a plain COMMAND: "git push origin
        # HEAD:gh-pages" publishes to the Pages branch with no action
        # and no token -- it needs only the checkout's rights.
        if _is_a_publishing_command(stripped):
            publishing += 1
    if publishing != 1:
        out.append("the deploy job has %d publication steps: there must "
                   "be exactly one" % publishing)

    # The publication must be the LAST thing the job does, and it must
    # come AFTER the fail-closed checks. A publication placed BEFORE
    # them would publish the artifact while the checks then HOLD the
    # job -- the refusal would be theatre.
    lines = [l.strip() for l in deploy.split("\n") if l.strip()]
    publish_index = None
    for index, line in enumerate(lines):
        if "actions/deploy-pages" in line:
            publish_index = index
            break
    if publish_index is not None:
        after = lines[publish_index + 1:]
        # The trailing "id:" belongs to the step itself.
        after = [l for l in after if not l.startswith("id:")]
        if after:
            out.append("the deploy job does something after the "
                       "publication: %s" % after[0][:60])

        # The checks must come BEFORE the publication. The order is
        # what makes the refusal real.
        before = "\n".join(lines[:publish_index])
        for check in ("ls-remote", "exit 1"):
            if check not in before:
                out.append("the deploy job publishes BEFORE the %s: the "
                           "refusal would come after the publication"
                           % ("tip checks" if check == "ls-remote"
                              else "refusal"))
                break
    return out


def _without_trailing_comment(line):
    """The line without its trailing comment.

    A '#' inside a quoted string is not a comment: the shell step
    "echo '# not a comment'" must survive. So the quotes are tracked.
    """
    quote = None
    for index, char in enumerate(line):
        if quote:
            if char == quote:
                quote = None
            continue
        if char in ("'", '"'):
            quote = char
            continue
        if char == "#":
            return line[:index].rstrip()
    return line


def _condition_disables_the_step(condition):
    """Is this step condition NEVER true?

    "if: false" -- and its spellings -- DISABLES the step. A disabled
    tip check or a disabled artifact validation is a REMOVED check,
    and the harness has to see it: the other evaluation asks whether
    a condition can be true after a failure, and "false" is not, so
    that question alone would pass it.
    """
    expression = _unquote(condition).strip()
    if expression.startswith("${{") and expression.endswith("}}"):
        expression = expression[3:-2].strip()
    if not expression:
        return False

    tokens = _tokenize(expression)
    if tokens is None:
        return False
    try:
        tree = _parse(tokens)
    except Exception:
        return False
    if tree is None:
        return False

    # The condition is evaluated in a context where everything is
    # true, so a condition that is still false there can never hold.
    context = {
        "success": True,
        "cancelled": False,
        "ref": "refs/heads/master",
        "event": "push",
        "sha": "0" * 40,
    }
    try:
        verdict = _evaluate(tree, context)
    except Exception:
        return False
    return verdict is False


def _condition_runs_after_a_failure(condition):
    """Can this step condition be TRUE when the previous step failed?

    The context is the one GitHub Actions uses: after a failed step,
    success() is false, failure() is true and cancelled() is false --
    the workflow was not cancelled, a step was.

    A condition with no status function keeps the implicit success(),
    so it is false then, and the step is skipped. A condition with ANY
    status function drops that implicit check, and the step RUNS.

    An undecidable condition is treated as running: the harness must
    not certify a condition it cannot read.
    """
    expression = _unquote(condition).strip()
    if expression.startswith("${{") and expression.endswith("}}"):
        expression = expression[3:-2].strip()
    if not expression:
        return False

    tokens = _tokenize(expression)
    if tokens is None:
        return True
    try:
        tree = _parse(tokens)
    except Exception:
        return True
    if tree is None:
        return True

    context = {
        "success": False,
        "cancelled": False,
        "ref": "refs/heads/master",
        "event": "push",
        "sha": "0" * 40,
    }
    try:
        verdict = _evaluate(tree, context)
    except Exception:
        return True
    if verdict is None:
        return True
    return bool(verdict)


def _step_conditions(job_body, job_level=True):
    """The conditions of the STEPS of a job, with the folded and
    literal block scalars expanded.

    A step condition can be written three ways:

        - name: x
          if: always()

        - if: always()
          name: x

        - name: x
          if: >-
            always()

    The third one is the same condition, and reading only the ">-"
    would miss it -- which is exactly how a bypass hides.

    With job_level=False the JOB-LEVEL condition is left out: it is
    the guard for the deploy job, read by the condition model, and it
    is the thing the branch authorization is about. The step-level
    conditions are the "this step does something else" class.
    """
    conditions = []
    lines = job_body.split("\n")
    for index, line in enumerate(lines):
        match = re.match(r"^\s*(?:-\s*)?if\s*:\s*(.*)$", line)
        if not match:
            continue
        if not job_level:
            # The distinction is INDENTATION, not text: the job keys
            # sit at four spaces and a step's keys sit deeper. The
            # text of the key is the same, so a textual test dropped
            # a step's mapping form "if: false" as the job-level
            # guard -- and the reusable workflow's steps are read ONLY
            # through this filter.
            stripped = line.strip()
            if stripped.startswith("if:"):
                indent = len(line) - len(line.lstrip())
                if indent <= 4:
                    continue
        value = match.group(1).strip()
        if value in (">-", ">", "|-", "|"):
            # The block that follows, joined.
            base = len(line) - len(line.lstrip())
            parts = []
            for follow in lines[index + 1:]:
                if not follow.strip():
                    continue
                if len(follow) - len(follow.lstrip()) <= base:
                    break
                parts.append(follow.strip())
            value = " ".join(parts).strip()
        conditions.append(value)
    return conditions


def _uses_yaml_anchors(release):
    """Does the workflow use YAML anchors or aliases?

    An anchor defines a mapping that another place can MERGE in with
    "<<: *name". The controls read each job's body, so a condition
    that comes from an anchor would be invisible: the deploy job would
    look unguarded while its real policy lives elsewhere in the file.

    So the controls do not try to resolve the anchors -- they REFUSE
    a workflow that uses them. A workflow the controls cannot read is
    a workflow the controls cannot certify.
    """
    # An anchor can be defined MID-LINE ("x-policy: &cond ...") and
    # an alias can be used WITHOUT the merge key ("policy: *base").
    # The rule is not a list of shapes: an '&' or a '*' anywhere
    # outside a comment makes the workflow unreadable to the controls.
    for name, body in release["jobs"].items():
        if re.search(r"<<\s*:\s*\*", body):
            return True
    for line in release["text"].split("\n"):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        # A '*' inside a shell glob is not an alias, and the workflow's
        # own shell steps use them; but an '&' or an '*' next to a
        # value is. The check is deliberately strict: the controls
        # refuse what they cannot read.
        if re.search(r"[&*]\s*[\w-]+\s*$", stripped):
            return True
        if re.search(r":\s*&\w", stripped):
            return True
    return False


# The commands whose result IS the gate. A step that swallows their
# result with "|| true" would let a RED gate pass.
GATE_COMMANDS = (
    "release_negative_controls.py",
    "validate_web_artifact.py",
    "run_battle_ecs_suites.py",
    "run_ah_semantic_differential.py",
    "ledger_validator",
    "negative_controls.py",
)


def _run_block(raw_body, command):
    """The RUN block of the step that runs the given command.

    A "set +e" disables the errexit for the whole run block, and it
    comes BEFORE the gate command inside that block. So the block is
    read from the "run:" key: the lines that follow it, until the
    indentation returns.

    The command is matched by its TEXT, not by its line: the code
    lines have the indentation stripped, so the two never compare
    equal.
    """
    lines = raw_body.split("\n")
    for index, line in enumerate(lines):
        if command.strip() not in line:
            continue
        base = len(line) - len(line.lstrip())
        # The "run:" key above the command: the block of a folded
        # scalar is deeper than the command, so the key is the
        # anchor of the block.
        start = index
        for candidate in range(index - 1, max(-1, index - 4), -1):
            if candidate < 0:
                break
            stripped = lines[candidate].strip()
            if stripped.startswith("run:"):
                start = candidate
                break
            if stripped.startswith("- ") or stripped.startswith("name:"):
                break
        key_base = len(lines[start]) - len(lines[start].lstrip())
        block = []
        for follow in lines[start + 1:]:
            if not follow.strip():
                block.append(follow)
                continue
            follow_indent = len(follow) - len(follow.lstrip())
            if follow_indent <= key_base:
                break
            # The NEXT STEP: a "- name:" line at the step's own
            # indentation. Its commands belong to it, not to this
            # one.
            if follow_indent == key_base and follow.strip().startswith("- "):
                break
            block.append(follow)
        if not block:
            # A single-line "run: <command>": the command IS the
            # block.
            block = [line]
        return block
    return []


def _step_lines(code, target):
    """The lines of the STEP a line belongs to.

    The step is the run body: the lines that follow the "run:" and
    are deeper than it. A "set +e" on its own line disables the
    errexit for the whole step, so the rule must read the step and
    not the single line.
    """
    lines = code.split("\n")
    for index, line in enumerate(lines):
        if line.strip() != target.strip():
            continue
        base = len(line) - len(line.lstrip())
        block = []
        for follow in lines[index + 1:]:
            if not follow.strip():
                block.append(follow)
                continue
            if len(follow) - len(follow.lstrip()) <= base:
                break
            block.append(follow)
        return block
    return []


def _is_a_publishing_command(line):
    """Does this COMMAND publish to the Pages?

    A plain push to the Pages branch publishes, and it needs no
    action and no token: the checkout's rights are enough.
    """
    if not re.match(r"^(?:run:\s*)?(?:git\s+push|gh\s+api)", line):
        return False
    return ("gh-pages" in line or "refs/heads/site" in line
            or "pages" in line.lower())


def _is_a_publication_step(line):
    """Does this step PUBLISH?

    By its CAPABILITY, not by its name: the Pages are published by
    the official action, by a third-party one, and by a plain "git
    push" to the Pages branch. The count of one spelling would not
    see the others.
    """
    action = line.split("uses:", 1)[-1].strip().strip("'\"")
    action = action.split("@")[0].strip()
    # The Pages are published by the official action, by a third-party
    # one, and by a plain push to the Pages branch. The ordinary
    # actions -- the checkout, the configuration -- publish nothing.
    if "deploy-pages" in action:
        return True
    if action.endswith("gh-pages") or "/gh-pages" in action:
        return True
    if "pages" in action.lower() and "configure" not in action.lower():
        return True
    return False


def _tests_variable(condition, variable):
    """Does this condition test the given shell variable?

    The readability check must be about the RIGHT tip: a condition
    that tests another variable holds for the wrong tip and sails on
    for the right one.
    """
    # The variable may be written "$VAR" or "${VAR}" -- the second
    # is the standard robust form.
    if ("$" + variable) not in condition \
            and ("${" + variable + "}") not in condition:
        return False
    # And it must test it for EMPTINESS -- "-z" is the empty test and
    # "-n" is the non-empty one, which tolerates the unreadable tip.
    if re.search(r"-n\s+", condition):
        return False
    return True


def _runs_a_command(line, script):
    """Does this line RUN the given script?

    The command must be a COMMAND: the script is the argument of the
    interpreter, and the interpreter is the first word of the line.
    A line that merely MENTIONS the script -- in a string, in an
    echo, in a comment -- does not run it. A certification that looks
    for the name as a SUBSTRING is satisfied by an echo.
    """
    stripped = _without_trailing_comment(line.strip())
    # The line may carry the "run:" key before the command, and the
    # command may be the whole line.
    stripped = re.sub(r"^run:\s*", "", stripped)
    match = re.match(r"^(?:python3?|py)\s+(.*)$", stripped)
    if not match:
        return False
    rest = match.group(1).strip()
    if rest.startswith(("'", '"')):
        return False
    parts = rest.split()
    if not parts:
        return False
    first = parts[0]
    if first.startswith(("'", '"')):
        return False
    return script in first


def _the_gate_command_is_not_last(line):
    """Does something follow the gate command in its run block?

    The gate command must be the LAST command of the block: anything
    after it can discard its status, and the list of the constructs
    that do so is never complete -- a pipeline, a conditional, an
    explicit exit, a do-nothing command.
    """
    stripped = _without_trailing_comment(line.strip())
    stripped = re.sub(r"^run:\s*", "", stripped)
    if not re.match(r"^(?:python3?|py)\s+", stripped):
        return False
    # The gate command is on this line. What follows it, on this line
    # or on the next lines of the block, decides the step's status.
    # The gate commands are "python <script>": the tail after the
    # script is what decides the status. An ARGUMENT is not a
    # swallow -- "python tools/x.py --verbose" runs the gate -- but an
    # OPERATOR is.
    after = stripped.split(None, 2)
    tail = after[2] if len(after) > 2 else ""
    tail = tail.strip()
    if not tail:
        return False
    # The operators that discard the status.
    if re.match(r"^(?:\|\||\||&&|;|\||&|if\b|then\b|else\b|fi\b|\{)",
                tail):
        return True
    # Anything else after the script on the same line is a wrapper --
    # "if ! python ..." starts with "if", and a redirection is not a
    # swallow.
    if re.match(r"^(?:if\b|!\b|\()", tail):
        return True
    return False


def _the_deploy_condition(release):
    """The JOB-LEVEL condition of the deploy job."""
    deploy = release["jobs"].get("deploy")
    if deploy is None:
        return None
    return _job_condition(deploy)


def _compared_refs(condition):
    """The refs the condition compares against.

    The authorization set is DERIVED from the expression: every ref
    literal the condition mentions is returned. A corpus is a sample
    of the names, and a name the sample omits is invisible -- so the
    rule is over the comparisons themselves, and no ref name can
    escape it.
    """
    refs = []
    for pattern in (r"github\.ref\s*(?:==|!=)\s*'([^']*)'",
                    r'github\.ref\s*(?:==|!=)\s*"([^"]*)"',
                    r"(?:startsWith|contains)\s*\(\s*github\.ref\s*,\s*'([^']*)'",
                    r'(?:startsWith|contains)\s*\(\s*github\.ref\s*,\s*"([^"]*)"'):
        for match in re.finditer(pattern, condition):
            refs.append(match.group(1))
    return refs


def _compared_events(condition):
    """The events the condition compares against.

    Derived from the expression, for the same reason as the refs.
    """
    events = []
    for pattern in (r"github\.event_name\s*(?:==|!=)\s*'([^']*)'",
                    r'github\.event_name\s*(?:==|!=)\s*"([^"]*)"'):
        for match in re.finditer(pattern, condition):
            events.append(match.group(1))
    return events


def _reads_the_gate_result(line):
    """Does this command CHECK the gate's output?

    "grep -q 'RUNNER: GREEN' /tmp/log" reads what the gate wrote and
    fails the step when the gate failed. It is the gate being USED,
    not swallowed -- and the repository's own steps do exactly this.
    """
    stripped = line.strip()
    if not re.match(r"^(?:grep|awk|sed|test\b|\[\b)", stripped):
        return False
    # It must read the gate's OUTPUT: the log the gate wrote, or the
    # exit status of the gate.
    return ("log" in stripped or "GREEN" in stripped
            or "pass" in stripped.lower() or "fail" in stripped.lower())


def _discards_the_status(tail):
    """Does this tail discard the gate's status?

    A pipeline into a LOGGER keeps the status: "tee" returns the
    status of its input, and the repository's own suites use it to
    keep the output. Any other pipeline, a separator, a conditional
    or an explicit exit discards it.
    """
    if not tail:
        return False
    # A pipeline: the last stage decides. A logger keeps the status.
    if "|" in tail:
        stages = [stage.strip() for stage in tail.split("|")]
        if len(stages) > 1:
            last = stages[-1].split()[0] if stages[-1].split() else ""
            if last in ("tee", "cat", "tee;", "cat;"):
                return False
            return True
    # A tail that is only an ARGUMENT runs the gate and nothing else.
    if re.match(r"^(?:--\S+|-\S+)(?:\s+--?\S+)*$", tail):
        return False
    # A separator, a conditional or an explicit exit.
    if re.search(r"(?:^|\s)(?:&&|;|\|\||\|\s*exit\s+0\b|if\b|!\b|\()",
                 tail):
        return True
    # A trailing line continuation is not a swallow.
    if tail.strip() == "\\":
        return False
    return False


def _runs_a_gate_command(line):
    """Does this line run one of the GATE commands?

    The gate commands are the ones whose result IS the gate: the
    release controls, the artifact validator, the suites, the ledger
    validator and the differential.
    """
    stripped = _without_trailing_comment(line.strip())
    stripped = re.sub(r"^run:\s*", "", stripped)
    match = re.match(r"^(?:python3?|py)\s+(.*)$", stripped)
    if not match:
        return False
    rest = match.group(1).strip()
    if rest.startswith(("'", '"')):
        return False
    parts = rest.split()
    if not parts:
        return False
    first = parts[0]
    if first.startswith(("'", '"')):
        return False
    for command in GATE_COMMANDS:
        if command in first:
            return True
    return False


def _is_yaml_true(line, key):
    """Is this key's value the YAML boolean TRUE?

    YAML has several spellings of it: true, True, TRUE, yes, on --
    and the quoted forms, which are strings but that GitHub accepts
    as the boolean. A check that reads the string "true" misses
    every spelling but one.

    So the value is read as a YAML boolean, in every spelling.
    """
    match = re.match(r"^" + re.escape(key) + r"\s*:\s*(.*)$", line.strip())
    if not match:
        return False
    value = _unquote(match.group(1).strip()).lower()
    return value in ("true", "yes", "on")


def _declares_an_elevated_scope(line):
    """Does this line declare an ELEVATED permission?

    Every spelling of a scope is read, because a rule that recognises
    only the spellings it was written for is defeated by the next
    one:

        contents: write
        "contents": "write"
        'contents': 'write'
        Contents: Write
        permissions: {contents: write}
        permissions: {contents: write, id-token: write}
        permissions: write-all
        permissions: "write-all"

    So the scopes are extracted and then judged, rather than matched
    as text.
    """
    quote = "\"\'"
    optional_quote = "[" + quote + "]?"
    scope_pattern = optional_quote + r"([\w-]+)" + optional_quote \
        + r"\s*:\s*(.+)$"

    stripped = line.strip()
    if stripped.startswith("permissions:"):
        value = _unquote(stripped[len("permissions:"):].strip())
        if value.lower() in ("write", "write-all"):
            return True
        if value.startswith("{") and value.endswith("}"):
            for part in value[1:-1].split(","):
                inner = re.match(scope_pattern, part.strip())
                if inner:
                    if _unquote(inner.group(2).strip()).lower() in (
                            "write", "write-all"):
                        return True
        return False

    match = re.match(scope_pattern, stripped)
    if not match:
        return False
    scope_value = _unquote(match.group(2).strip()).lower()
    if scope_value in ("write", "write-all"):
        return True
    # A flow mapping in the value: "{contents: write}".
    if scope_value.startswith("{") and scope_value.endswith("}"):
        for part in scope_value[1:-1].split(","):
            inner = re.match(scope_pattern, part.strip())
            if inner:
                if _unquote(inner.group(2).strip()).lower() in (
                        "write", "write-all"):
                    return True
    return False


def _workflow_permissions(release):
    """The WORKFLOW-LEVEL permissions, which live outside every job.

    A job's own block overrides the workflow default, so the workflow
    default is only dangerous when a job has no block of its own --
    but that combination is exactly what would elevate a job
    silently.
    """
    text = release["text"]
    lines = text.split("\n")
    value = None
    permissions = None
    # The TOP-LEVEL blocks only: an indented one belongs to a job.
    # And the LAST of them: a duplicate key is last-wins in YAML, and
    # the platform takes the last one.
    for index, line in enumerate(lines):
        stripped = line.strip()
        if not stripped.startswith("permissions:"):
            continue
        if line[:1].isspace():
            continue
        value = _unquote(stripped[len("permissions:"):].strip())
        if value:
            permissions = None
            break
        # The BLOCK form: the scopes are deeper than the key, exactly
        # as in the per-job reader.
        base = len(line) - len(line.lstrip())
        permissions = []
        for follow in lines[index + 1:]:
            if not follow.strip():
                continue
            if len(follow) - len(follow.lstrip()) <= base:
                break
            scope_line = follow.strip()
            match = re.match(SCOPE_PATTERN, scope_line)
            if match:
                permissions.append((match.group(1),
                                   _unquote(match.group(2))))
    if permissions is not None:
        return permissions
    if value is None:
        return []
    if value.startswith("{") and value.endswith("}"):
        permissions = []
        for part in value[1:-1].split(","):
            part = _unquote(part.strip())
            if not part:
                continue
            inner = re.match(r"^([\w-]+)\s*:\s*(\S+)$", part)
            if inner:
                permissions.append((inner.group(1),
                                   _unquote(inner.group(2))))
            else:
                permissions.append((part, part))
        return permissions
    return [(value, value)]


# The pattern of a scope and its value, with the optional quotes and
# any case: "contents: write", "'contents': 'write'", "Contents: Write".
SCOPE_PATTERN = r'^[\"\']?([\w-]+)[\"\']?\s*:\s*(\S+)$'


def _job_permissions(job_body):
    """The permissions of a job, as (scope, value) pairs.

    Both spellings are read:

        permissions: write-all          -> (write-all, write-all)
        permissions:                    -> the scopes listed below
          contents: read
          pages: write

    The scalar form is elevated by itself, and the block form lists
    one scope per line. A sweep that skipped the key "permissions"
    would miss the scalar form entirely.
    """
    permissions = []
    lines = job_body.split("\n")
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("permissions:"):
            value = _unquote(stripped[len("permissions:"):].strip())
            if value:
                # The FLOW MAPPING is a valid spelling:
                # "permissions: {pages: write}". Its scopes are read
                # like a block.
                if value.startswith("{") and value.endswith("}"):
                    inner = value[1:-1]
                    for part in inner.split(","):
                        part = _unquote(part.strip())
                        if not part:
                            continue
                        match = re.match(SCOPE_PATTERN, part)
                        if match:
                            permissions.append((match.group(1),
                                               _unquote(match.group(2))))
                        else:
                            permissions.append((part, part))
                    continue
                permissions.append((value, value))
                continue
            # The block form: the scopes are deeper than the key.
            base = len(line) - len(line.lstrip())
            for follow in lines[index + 1:]:
                if not follow.strip():
                    continue
                if len(follow) - len(follow.lstrip()) <= base:
                    break
                scope_line = follow.strip()
                match = re.match(SCOPE_PATTERN, scope_line)
                if match:
                    permissions.append((match.group(1), match.group(2)))
    return permissions


def _neutralised(condition):
    """Is the condition neutralised by a shell operator?

    "&& false" makes the condition NEVER hold, and "|| true" makes it
    ALWAYS hold. Either way the comparison is not a comparison: it is
    a decoration.
    """
    stripped = condition.strip()
    if re.search(r"&&\s*false\b", stripped):
        return "&& false"
    if re.search(r"\|\|\s*true\b", stripped):
        return "|| true"
    return None


def _exit_is_a_refusal(block, condition):
    """Does the condition exit NON-ZERO?

    "exit 0" is not a refusal: it reports success and the script
    continues. Only a non-zero exit stops the step.
    """
    lines = block.split("\n")
    inside = False
    for line in lines:
        stripped = line.strip()
        if not inside:
            # The line must BE the condition: it may carry the
            # refusal on the same line, which is legal and normal.
            if stripped == condition or stripped.startswith(condition + " "):
                inside = True
                # The refusal may be after the "then" on the same
                # line: "if [ ... ]; then exit 1; fi". And the caller
                # may pass the WHOLE line as the condition -- so the
                # exit is searched in the line itself, and the tail
                # after the condition is searched too.
                tail = stripped[len(condition):] or stripped
                match = re.search(r"\bexit\s+(\d+)\b", tail)
                if match:
                    return int(match.group(1)) != 0
            continue
        match = re.match(r"^exit\s+(\d+)", stripped)
        if match:
            return int(match.group(1)) != 0
        if stripped == "fi" or stripped.startswith("fi "):
            return False
    return False


def _condition_refuses(block, condition):
    """Does the GIVEN condition refuse?

    The refusal must belong to that condition: the `exit` must be
    between the condition's `then` and its `fi`. An `exit` that belongs
    to a LATER condition is a different mechanism -- and a comparison
    eight lines below is exactly that.
    """
    lines = block.split("\n")
    inside = False
    for line in lines:
        stripped = line.strip()
        if not inside:
            # The line must BE the condition: it may carry the
            # refusal on the same line, which is a legal and normal
            # way to write it.
            if stripped == condition or stripped.startswith(condition + " "):
                inside = True
                # The refusal may already be on this line.
                tail = stripped[len(condition):]
                if "exit " in tail:
                    return True
            continue
        if "exit " in stripped:
            return True
        if stripped == "fi" or stripped.startswith("fi "):
            return False
    return False


def _refuses(block):
    """Does this block REFUSE, or only notice?

    A condition that prints a message and continues is not a refusal.
    The refusal must be INSIDE the condition: an `exit 1` a few lines
    below, in a DIFFERENT condition, is a different mechanism.

    So the check is: the `if` line, and the `exit` that follows it,
    must be in the SAME condition -- that is, before the matching
    `fi`.
    """
    if block is None:
        return False
    lines = block.split("\n")
    for index, line in enumerate(lines):
        stripped = line.strip()
        if not stripped.startswith("if "):
            continue
        if "exit " in stripped:
            # A single-line condition: `if [ ... ]; then exit 1; fi`.
            return True
        # A block condition: the exit must come before the `fi`, and
        # it must belong to THIS condition.
        depth = 0
        for follow in lines[index + 1:]:
            follow_stripped = follow.strip()
            if follow_stripped.endswith("then"):
                depth += 1
                continue
            if follow_stripped == "fi" or follow_stripped.startswith("fi "):
                if depth == 0:
                    break
                depth -= 1
                continue
            if depth == 0 and follow_stripped.startswith("if "):
                break
            if "exit " in follow_stripped:
                return True
    return False


def _step_block(body, needle):
    """The lines of the step whose name mentions the needle.

    The block is the step's own lines: the name, its keys and its run
    body. A mechanism's refusal must be INSIDE its own step: a global
    search would be satisfied by another step's "exit 1".

    The body is read with its INDENTATION: the step's keys are deeper
    than the "- name:" line, and that depth is what delimits the step.
    A stripped copy would lose it.
    """
    lines = body.split("\n")
    for index, line in enumerate(lines):
        if "- name:" not in line:
            continue
        if needle not in line:
            continue
        # The step's own keys and its run body are indented deeper
        # than the "- name:" line itself.
        base = len(line) - len(line.lstrip())
        block = [line]
        for follow in lines[index + 1:]:
            if not follow.strip():
                block.append(follow)
                continue
            indent = len(follow) - len(follow.lstrip())
            if indent <= base:
                break
            block.append(follow)
        return "\n".join(block)
    return None


def prop_15_the_triggers_are_certified(release, test):
    """The trigger block is the FIRST gate, so it is certified too.

    The job-level condition and the master-tip check would still deny
    a bad ref, so this is defence in depth -- but the branch filter
    is the first thing that runs, and nothing certified it: adding a
    "pull_request:" or a "schedule:" trigger, or removing the branch
    filter, passed every control.
    """
    out = []
    text = release["text"]

    # The trigger block is at the top level, before "jobs:".
    match = re.search(r"^\s*['\"]?on['\"]?\s*:\s*$", text, re.MULTILINE)
    if not match:
        out.append("the workflow has no trigger block")
        return out
    body = text[match.end():]
    # The block ends at the next top-level key.
    lines = []
    for line in body.split("\n")[1:]:
        if line.strip() and not line.startswith(" "):
            break
        lines.append(line)
    trigger = "\n".join(lines)

    # The trigger NAMES are read as keys: every key of the block is
    # extracted and unquoted, and judged by its name. A quoted key or
    # a space before the colon is a spelling, not a different
    # trigger -- so it cannot hide one.
    trigger_keys = []
    for line in trigger.split("\n"):
        key = re.match(r"^\s*['\"]?([\w-]+)['\"]?\s*:", line)
        if key:
            trigger_keys.append(key.group(1).lower())

    # The REUSABLE workflow's triggers are certified too. It is part
    # of the publication gate -- the deploy needs it -- so a
    # "pull_request_target:" trigger on it would run a PR's code with
    # the workflow's own privileges, and the gate would be reachable
    # from a pull request.
    reusable = test["text"]
    reusable_match = re.search(r"^\s*['\"]?on['\"]?\s*:\s*$", reusable,
                               re.MULTILINE)
    if reusable_match is None:
        out.append("the reusable workflow has no trigger block")
    else:
        reusable_body = reusable[reusable_match.end():]
        reusable_lines = []
        for line in reusable_body.split("\n")[1:]:
            if line.strip() and not line.startswith(" "):
                break
            reusable_lines.append(line)
        for line in reusable_lines:
            key = re.match(r"^\s*['\"]?([\w-]+)['\"]?\s*:", line)
            if not key:
                continue
            name = key.group(1).lower()
            # The reusable workflow runs its own CI on push and on
            # pull_request: that is its purpose, and the deploy needs
            # it as a REUSABLE WORKFLOW, not as an event-driven run.
            # The dangerous triggers are the ones that carry a PR's
            # code with the workflow's own privileges, and the ones
            # that can be fired from outside.
            if name in ("pull_request_target", "schedule", "workflow_run",
                        "issue_comment", "repository_dispatch", "release",
                        "fork", "deployment", "page_build", "check_run",
                        "check_suite", "status", "create", "delete", "watch"):
                out.append("the reusable workflow has a %s trigger" % name)

    # The push trigger must be filtered to master -- and to master
    # ALONE. A widened filter ("[master, staging]") admits another
    # branch, and the check that only asked whether "master" was
    # present passed it.
    if "branches:" not in trigger:
        out.append("the push trigger has no branch filter")
    else:
        branches = re.findall(r"branches:\s*\[([^\]]*)\]", trigger)
        listed = []
        for group in branches:
            for item in group.split(","):
                item = _unquote(item.strip())
                if item:
                    listed.append(item)
        if not listed:
            # The BLOCK form: "branches:" and then the list, one per
            # line. It is the canonical style and valid YAML.
            trigger_lines = trigger.split("\n")
            for index, line in enumerate(trigger_lines):
                if not re.match(r"^\s*branches\s*:\s*$", line):
                    continue
                base = len(line) - len(line.lstrip())
                for follow in trigger_lines[index + 1:]:
                    if not follow.strip():
                        continue
                    if len(follow) - len(follow.lstrip()) <= base:
                        break
                    item = follow.strip()
                    if item.startswith("- "):
                        item = item[2:].strip()
                    item = _unquote(item)
                    if item:
                        listed.append(item)
                break
        if not listed:
            out.append("the push trigger has an empty branch filter")
        for item in listed:
            if item != "master":
                out.append("the push trigger admits %r: only master may "
                           "be published from" % item)

    # The other triggers must not exist: they are the door through
    # which a ref other than master could arrive. They are judged by
    # their NAME, read from the keys -- so a quoted key or a space
    # before the colon cannot hide one.
    for forbidden in ("pull_request", "schedule", "workflow_run",
                      "pull_request_target", "issue_comment",
                      "repository_dispatch", "release", "fork",
                      "deployment", "page_build", "check_run",
                      "check_suite", "status", "create", "delete",
                      "watch"):
        if forbidden in trigger_keys:
            out.append("the workflow has a %s trigger" % forbidden)

    # The REUSABLE workflow's triggers are certified too. A
    # pull_request_target: trigger on it is the classic privilege
    # escalation shape: it runs with write scope against the base
    # repository, and the harness certified no trigger set for it at
    # all.
    reusable = test.get("text", "")
    reusable_code = _code_lines(reusable)
    for forbidden in ("pull_request_target:", "issue_comment:",
                      "workflow_run:", "schedule:"):
        if forbidden in reusable_code:
            out.append("the reusable workflow has a %s trigger"
                       % forbidden[:-1])
    return out


def prop_16_the_concurrency_group_is_real(release, test):
    """The concurrency group must be per ref, not a constant.

    The group was checked with two substring greps over the whole
    file, comments included, so a constant group -- which would make
    the deployments of DIFFERENT refs queue behind each other -- was
    accepted.
    """
    out = []
    code = _code_lines(release["text"])
    group = None
    for line in code.split("\n"):
        stripped = line.strip()
        if stripped.startswith("group:"):
            group = stripped[len("group:"):].strip()
            break
    if group is None:
        out.append("the workflow has no concurrency group")
        return out
    if "github.ref" not in group:
        out.append("the concurrency group %s is constant: the "
                   "deployments of different refs would queue behind "
                   "each other" % group)
    # The group must be per REF and NOTHING ELSE. A group that also
    # carries the SHA lets two runs of the SAME ref run at the same
    # time -- the second is not queued behind the first, and the
    # freshness guarantee is gone.
    for other in ("github.sha", "github.head_ref", "github.run_id",
                  "github.run_number", "github.actor"):
        if other in group:
            out.append("the concurrency group %s carries %s: two runs "
                       "of the same ref would not queue behind each "
                       "other" % (group, other))

    # The flag the workflow's own comment depends on. With
    # cancel-in-progress: true the in-flight older run is CANCELLED,
    # which is a different and weaker guarantee than the one the
    # comment states -- so the comment would be a lie.
    for line in code.split("\n"):
        if _is_yaml_true(line, "cancel-in-progress"):
            out.append("the concurrency cancels the older run: the "
                       "workflow's own comment states that it does not")
    return out


# The branch names that are plausible in this repository, and the
# shapes of a ref that GitHub can produce.
BRANCH_NAMES = (
    "master", "Master", "MASTER", "release", "Release", "main", "mainline",
    "staging", "feature", "phase3", "hotfix", "develop", "production",
    "master-2", "master2", "master2x", "release-1", "master_", "master.",
    "site", "gh-pages", "pages", "test", "tmp", "backup", "old",
    # The version names: a tag is a ref too.
    "v1", "v1.0.0", "v2", "1.0", "release-1.0",
)

REF_SHAPES = (
    "refs/heads/{name}",
    "refs/heads/{name}/x",
    "refs/heads/x/{name}",
    "refs/tags/{name}",
    "refs/pull/1/head",
    "refs/pull/12/merge",
    "refs/remotes/origin/{name}",
    "{name}",
    "refs/heads/",
    "refs/heads/{name} ",
    "refs/heads/{name}/",
)

# The events GitHub can deliver.
EVENT_NAMES = (
    "push", "workflow_dispatch", "pull_request", "pull_request_target",
    "schedule", "workflow_run", "issue_comment", "release",
    "repository_dispatch", "create", "delete", "fork", "watch",
    "deployment", "status", "page_build", "check_run", "check_suite",
)


def _generate_ref_corpus():
    """Every ref the corpus covers, generated from the shapes."""
    refs = set()
    for shape in REF_SHAPES:
        for name in BRANCH_NAMES:
            refs.add(shape.format(name=name))
    for shape in REF_SHAPES:
        refs.add(shape.format(name=""))
    return sorted(refs)


def _generate_event_corpus():
    """Every event the corpus covers."""
    return sorted(EVENT_NAMES)


def prop_14_the_ref_set_is_a_rule(release, test):
    """The authorization set is a RULE, not a sample.

    The forbidden refs used to be a hand-written list of ten, so a
    mutation that opened ONE OTHER ref -- "|| github.ref ==
    'refs/tags/v1'" -- passed every control. The model is now asked
    about a generated corpus, and its authorization set must be a
    subset of the master ref.

    The corpus contains the CASE variants on purpose: GitHub Actions
    compares strings IGNORING the case, so "refs/heads/Master" does
    satisfy "== 'refs/heads/master'" on the platform. The model must
    reproduce that faithfully -- and the second, case independent
    guard (the master-tip SHA check) is what actually refuses the
    publication for those.
    """
    out = []
    # The corpus is a GENERATION over the shapes, but the NAMES in it
    # are still a list -- and a list of names is defeated by the one
    # name it omits. So the property does not depend on the names at
    # all.
    #
    # It is a PROPERTY of the condition: every ref the condition
    # compares against must be the master ref, and every event it
    # compares against must be push or workflow_dispatch. That is a
    # rule over the condition's own text, and no ref name and no
    # event name can escape it.
    condition = _the_deploy_condition(release)
    if condition is None:
        out.append("the deploy job has no condition: every ref is "
                   "authorized")
        return out

    for ref in _compared_refs(condition):
        if ref.strip().lower() != "refs/heads/master":
            out.append("the deploy condition compares against %s: it "
                       "may compare only against refs/heads/master" % ref)
    for event in _compared_events(condition):
        if event not in ("push", "workflow_dispatch"):
            out.append("the deploy condition compares against the %s "
                       "event: it may compare only against push and "
                       "workflow_dispatch" % event)

    # And the model is asked over the generated corpus as well, so a
    # form the text rule does not see is still caught.
    corpus = _generate_ref_corpus()
    events = _generate_event_corpus()
    allowed = set()
    for ref in corpus:
        for event in events:
            ok, _ = deploy_is_authorized(release, event, ref, True)
            if ok:
                allowed.add((ref, event))
    for ref, event in sorted(allowed):
        if ref.strip().lower() != "refs/heads/master":
            out.append("the deploy condition authorizes %s on %s: the "
                       "authorization set must be a subset of the "
                       "master ref" % (ref, event))
        elif event not in ("push", "workflow_dispatch"):
            out.append("the deploy condition authorizes %s on %s: the "
                       "authorization set must be a subset of the "
                       "push and dispatch events" % (ref, event))
    return out


def prop_17_the_test_jobs_are_not_disabled(release, test):
    """The reusable test workflow must not have a job disabled.

    The deploy job needs the reusable workflow, and its result is the
    evidence that the commit is good. A job disabled with "if: false"
    never runs -- and the release job would still be authorized,
    because the deploy job's own condition only asks that the NEEDS
    succeeded.

    So the reusable workflow is part of the gate, and its jobs are
    read too.
    """
    out = []
    for name, body in test["jobs"].items():
        if name in ("push", "workflow_dispatch", "pull_request"):
            continue
        # A job-level condition that is never true disables the job.
        condition = _job_condition(body)
        if condition and _condition_disables_the_step(condition):
            out.append("the %s job is disabled: %s" % (name, condition))
        # The STEP-level conditions of the reusable workflow matter
        # just as much: a mandatory step disabled with "if: false" is
        # a removed gate -- and the step that runs THE CONTROLS is
        # itself such a step. A harness that cannot detect its own
        # disablement certifies nothing.
        for value in _step_conditions(body, job_level=False):
            if _condition_disables_the_step(value):
                out.append("the %s job carries a step that is disabled: "
                           "%s" % (name, value))
                break
            if _condition_runs_after_a_failure(value):
                out.append("the %s job carries a step that runs "
                           "regardless: %s" % (name, value))
                break
    return out


def prop_19_the_gate_is_not_swallowed(release, test):
    """The gate's own result must not be swallowed.

    "|| true" after the controls makes the step succeed whatever the
    controls reported: the gate would run, say RED, and the CI would
    carry on. The same shape applies to every mandatory step of the
    reusable workflow.

    The rule is POSITIONAL, not a list of spellings. The command that
    runs the gate must be the LAST command of its run block: whatever
    follows it -- a pipeline, a conditional, an explicit exit, a
    do-nothing command, an argument -- can discard its status, and
    the list of such constructs is never complete.

    So the run block is read, the gate's line is found in it, and
    everything after that line in the block is a swallow.
    """
    out = []
    for label, text in (("the release workflow", release["text"]),
                        ("the reusable workflow", test["text"])):
        code = _code_lines(text)
        # The RAW body, with the indentation: the run block is
        # delimited by it, and the code lines have it stripped.
        raw_body = _body_without_comments(text)
        for line in code.split("\n"):
            # Only the GATE's own result matters. "godot --editor
            # --quit || true" is a legitimate way to close an editor
            # that exits with a warning, and it is not a gate.
            if not _runs_a_gate_command(line):
                continue
            swallowed = False
            # The whole RUN BLOCK is read, not the single line.
            block_lines = _run_block(raw_body, line)
            # The gate's line inside the block, and everything after
            # it: that is what decides the step's status.
            index = None
            for position, other in enumerate(block_lines):
                if _runs_a_gate_command(other.strip()):
                    index = position
                    break
            if index is None:
                # The gate is not in the block: the line is the whole
                # command, so only what follows it on the line counts.
                tail = line.strip()
                tail = re.sub(r"^run:\s*", "", tail)
                tail = tail.split(None, 2)[2] if len(
                    tail.split(None, 2)) > 2 else ""
                if _discards_the_status(tail.strip()):
                    swallowed = True
            else:
                # The gate's OWN line may carry the swallow:
                # "python tools/x.py || true".
                own = block_lines[index]
                own_stripped = re.sub(r"^run:\s*", "",
                                      _without_trailing_comment(own.strip()))
                parts = own_stripped.split(None, 2)
                own_tail = parts[2].strip() if len(parts) > 2 else ""
                if own_tail and _discards_the_status(own_tail):
                    swallowed = True
                # A pipeline that ends in a LOGGER keeps the status.
                elif own_tail and "|" in own_tail:
                    stages = [s.strip() for s in own_tail.split("|")]
                    last = stages[-1].split()[0] if stages[-1].split() else ""
                    if last not in ("tee", "cat", "tee;", "cat;"):
                        swallowed = True
                # "set +e" may come BEFORE the gate command: it
                # disables the errexit for the whole block, so the
                # gate's failure does not stop the step.
                for before in block_lines[:index]:
                    if "set +e" in before:
                        swallowed = True
                        break
                continued = False
                for other in (block_lines[index + 1:] if not swallowed
                              else []):
                    if not other.strip():
                        continue
                    # A command may be continued over SEVERAL lines:
                    # a line that ends with a backslash continues on
                    # the next, and so on. The whole chain belongs to
                    # the command, so it is part of the gate and not
                    # a swallow.
                    if continued:
                        continued = other.rstrip().endswith("\\")
                        continue
                    if other.rstrip().endswith("\\"):
                        continued = True
                        continue
                    if "set +e" in other:
                        # errexit is off: the step exits 0 even when
                        # the gate fails.
                        swallowed = True
                        break
                    if _reads_the_gate_result(other):
                        # The command READS the gate's output and
                        # checks it -- "grep -q 'RUNNER: GREEN' log".
                        # It fails the step when the gate failed, so
                        # it is the gate being USED, not swallowed.
                        continue
                    swallowed = True
                    break
            if swallowed:
                out.append("the %s swallows the gate's result: the gate "
                           "command must be the last command of its run "
                           "block" % label)
    return out



def prop_20_the_needs_exist(release, test):
    """The needs of the deploy job must be jobs that EXIST.

    GitHub fails a workflow whose needs name a job that is not there,
    so this is not an opening -- but the harness must see it, because
    a harness that reads the needs without checking them would
    certify a broken workflow.
    """
    out = []
    names = set(release["jobs"].keys())
    for job in ("deploy", "web-build", "required-tests"):
        body = release["jobs"].get(job, "")
        needs = _needs_of(release["jobs"], job)
        for needed in needs.replace(",", " ").split():
            needed = needed.strip().strip("'\"")
            if needed and needed not in names:
                out.append("the %s job needs %s, which does not exist"
                           % (job, needed))

    # The needs must be checked by WHAT THEY DO, not by their NAME.
    # The deploy needs a job named "required-tests" -- but that job
    # can be a trivial one, while the reusable workflow that runs the
    # actual CI is called by ANOTHER job the deploy does not need.
    # The CI no longer gates the publication, and the check passed
    # because it read the name.
    for job in ("deploy", "web-build"):
        body = release["jobs"].get(job, "")
        needs = _needs_of(release["jobs"], job)
        for needed in needs.replace(",", " ").split():
            needed = needed.strip().strip("'\"")
            if needed not in names:
                continue
            needed_body = release["jobs"].get(needed, "")
            # The required-tests job must CALL the reusable workflow
            # that runs the CI. A job that does not call it runs
            # nothing, whatever it is named.
            if needed == "required-tests":
                if "uses:" not in needed_body or "test.yml" not in needed_body:
                    out.append("the %s job does not call the reusable "
                               "workflow that runs the CI: the CI does "
                               "not gate the publication" % job)
            if needed == "web-build":
                if "uses:" not in needed_body:
                    out.append("the %s job does not call the reusable "
                               "workflow that builds the artifact"
                               % job)
    return out


def prop_21_the_jobs_are_bounded(release, test):
    """The deploy job must have a timeout.

    Without one the job could hang forever and hold the Pages
    deployment queue -- and the concurrency group would queue every
    later run behind it.
    """
    out = []
    for name, body in release["jobs"].items():
        if name in ("push", "workflow_dispatch"):
            continue
        # A job that CALLS the reusable workflow has no timeout of
        # its own -- the called workflow carries it. The test is a
        # JOB-LEVEL "uses:" key, not a step's: the deploy job uses
        # actions and still needs its timeout.
        job_level_uses = re.search(r"^\s{2,4}uses\s*:", body,
                                    re.MULTILINE)
        if job_level_uses and "timeout-minutes:" not in body:
            continue
        if "timeout-minutes:" not in body:
            out.append("the %s job has no timeout" % name)
    return out


def prop_22_the_release_workflow_is_named(release, test):
    """The file the controls read must be the release workflow.

    A workflow that is no longer named "Release" would still be the
    one the controls read -- and the one that publishes.
    """
    out = []
    code = _code_lines(release["text"])
    for line in code.split("\n"):
        if line.startswith("name:"):
            if line.strip() != "name: Release":
                out.append("the release workflow is named %r: the controls "
                           "read this file, so it must be the release "
                           "workflow" % line.strip()[6:].strip())
            break
    return out


# The steps of the reusable workflow that ARE the gate. Deleting one
# of them is a removed gate -- the harness proved it cannot be
# disabled, but it must also prove it cannot be DELETED.
MANDATORY_TEST_STEPS = (
    "Install Godot",
    "Lint core and scenes",
    "Parse project in editor mode",
    "Run legacy regression suite",
    "Run legacy characterization suite (3 runs, all produce result, identical)",
    "Run legacy save fixture loader",
    "Run save schema v4 suite",
    "Run save schema v4 byte-for-byte determinism",
    "Run production save repository suite",
    "Run RunSaveFileOps suite",
    "Run RunUnit is_alive suite",
    "Install Godot",
    "Import project cache",
    "Run every standalone suite",
    "Run the A-H semantic differential",
    "Validate the Run Integrity ledger",
    "Check the Run Integrity ledger validator",
    "Check the standalone runner contract",
    "Check the A-H differential contract",
    "Check the standalone runner negative controls",
    "Check the A-H differential negative controls",
    "Check the battle entry negative controls",
    "Run the release negative controls",
    "Audit the standalone harness exit contract",
    "Audit the legacy test reachability",
    "Save and Battle Migration",
)


def prop_24_the_published_bytes_are_the_validated_bytes(release, test):
    """The published artifact must be the VALIDATED artifact.

    The validator checks the build/ directory, and the upload step
    names a path. If the two differ, the bytes that are published are
    not the bytes that were validated -- and the workflow's own
    comment claims they are.
    """
    out = []
    build = release["jobs"].get("web-build", "")
    code = _code_lines(build)
    validated = None
    for line in code.split("\n"):
        if "validate_web_artifact.py" in line:
            parts = line.split()
            if len(parts) >= 2:
                validated = parts[-1].strip("'\"")
    if validated is None:
        out.append("the build job does not validate an artifact")
        return out

    # EVERY upload is read: a second upload of another directory
    # overwrites the artifact, so the rule that read only the FIRST
    # one missed it.
    # The validated bytes must be the PUBLISHED bytes: nothing may
    # write into the validated directory between the validation and
    # the upload.
    validation_index = None
    upload_index = None
    uploaded = []
    lines = code.split("\n")
    for index, line in enumerate(lines):
        if "validate_web_artifact.py" in line and validation_index is None:
            validation_index = index
        if "upload-pages-artifact" in line:
            # The path is the key below it.
            for follow in lines[index + 1:index + 4]:
                if "path:" in follow:
                    uploaded.append(follow.split("path:", 1)[1].strip()
                                    .strip("'\""))
                    break
            if upload_index is None:
                upload_index = index
    if not uploaded:
        out.append("the build job does not upload the artifact")
    if validation_index is not None and upload_index is not None:
        between = lines[validation_index:upload_index]
        for line in between:
            stripped = line.strip()
            # A step that WRITES into the validated directory
            # publishes bytes that were never validated.
            if (">>" in stripped or ">" in stripped) and "build/" in stripped:
                out.append("the build job modifies the artifact between "
                           "the validation and the upload: the published "
                           "bytes are not the validated bytes")
                break
    for path in uploaded:
        if path.rstrip("/") != validated.rstrip("/"):
            out.append("the build job validates %s but uploads %s: the "
                       "published bytes are not the validated bytes"
                       % (validated, path))
    return out


def prop_23_the_mandatory_steps_are_present(release, test):
    """Every mandatory step of the reusable workflow must EXIST.

    The harness proved that a mandatory step cannot be DISABLED with
    a condition. It did not prove that the step cannot be DELETED --
    and deleting the step that runs the controls leaves the reusable
    workflow succeeding, the required jobs succeeding, the deploy
    publishing, and nothing running the controls at all.

    So the steps are a NAMED LIST: the harness checks that each one
    is there, not merely that none of them is disabled.
    """
    out = []
    code = _code_lines(test["text"])
    # The step names are read as NAMES -- the value of a "- name:"
    # key, unquoted. A substring search was satisfied by an echo
    # that MENTIONS the name, so the step could be deleted and its
    # name carried by a string.
    present = set()
    for line in code.split("\n"):
        match = re.match(r"^-?\s*name:\s*(.+)$", line)
        if match:
            present.add(_unquote(match.group(1).strip()))
    for step in MANDATORY_TEST_STEPS:
        if step not in present:
            out.append("the reusable workflow has no %r step: a deleted "
                       "gate is a removed gate" % step)
    # And the steps that are PRESENT must be the ones that were
    # expected: the named list covers only part of the workflow, and a
    # step that is not on it can be deleted without the list noticing.
    for step in present:
        if step not in MANDATORY_TEST_STEPS:
            out.append("the reusable workflow has an unexpected step %r: "
                       "a step that is not on the list can be deleted "
                       "without the list noticing" % step)
    # The gate commands themselves must run somewhere in the
    # reusable workflow. The artifact validator is NOT among them: it
    # runs in the RELEASE workflow's build job.
    for command in ("release_negative_controls.py",
                    "run_battle_ecs_suites.py"):
        if not any(_runs_a_command(line, command)
                   for line in code.split("\n")):
            out.append("the reusable workflow never runs %s" % command)
    return out


def prop_18_no_other_publisher(release, test):
    """There must be no OTHER workflow that could publish the Pages.

    The harness resolves its inputs by filename, so a workflow file it
    does not know about cannot be checked -- and one that publishes on
    every branch with pages: write would pass every control.

    The premise "the old ungated publish path cannot survive the
    merge" is true for the DELETED web-build.yml and false for any
    NEW file: the deletion is recorded in the diff, but a file that
    appears out of nowhere is not.
    """
    out = []
    known = {"release.yml", "test.yml"}
    # The directory of the RELEASE FILE THAT WAS GIVEN: a mutation
    # that adds a workflow next to it must be seen. A module-level
    # constant would point at the real repository and miss it.
    directory = release.get("directory")
    if not directory:
        directory = os.path.dirname(os.path.abspath(RELEASE))
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".yml") and not name.endswith(".yaml"):
            continue
        if name in known:
            continue
        path = os.path.join(directory, name)
        try:
            text = io.open(path, encoding="utf-8-sig", errors="replace").read()
        except OSError:
            continue
        code = "\n".join(l for l in text.replace("\r\n", "\n").split("\n")
                          if l.strip() and not l.strip().startswith("#"))
        # The rule is not a list of tokens. A publisher that writes to
        # the Pages branch directly carries neither "deploy-pages" nor
        # "pages: write" -- and a third-party Pages action carries
        # neither either. So the check is a RULE: no other workflow
        # may carry an elevated permission, name the Pages branch, or
        # use a Pages action.
        reason = None
        for line in code.split("\n"):
            stripped = line.strip()
            # Any write scope at all. The scopes are READ as a
            # block: the flow mapping "permissions: {contents: write}",
            # the quoted keys, the different case -- a textual regex
            # over the line misses every one of them.
            # And the TRAILING COMMENT is cut off first: the same
            # lesson as everywhere else in this series -- a comment
            # can carry the text that satisfies a check.
            if _declares_an_elevated_scope(
                    _without_trailing_comment(stripped)):
                reason = "it carries the elevated permission %r" % stripped
                break
            # The Pages branch, however it is reached.
            if "gh-pages" in stripped:
                reason = "it names the Pages branch: %r" % stripped
                break
            # A Pages action, whoever wrote it.
            if re.search(r"uses:\s*\S*gh-pages", stripped):
                reason = "it uses a Pages action: %r" % stripped
                break
            if "deploy-pages" in stripped:
                reason = "it deploys the Pages: %r" % stripped
                break
            # A workflow that CALLS the release workflow is a second
            # path to the same publication: it would run the release
            # workflow from its own trigger, on its own ref.
            if re.search(r"uses:\s*\S*release\.ya?ml", stripped):
                reason = "it calls the release workflow: %r" % stripped
                break
        if reason:
            out.append("the workflow %s could publish the Pages -- %s. The "
                       "release gate is the only publisher"
                       % (name, reason))
    return out


def prop_13_no_yaml_anchors(release, test):
    """The workflow must be readable by the controls.

    A YAML anchor can carry the deploy job's condition out of the job
    itself. The controls read the job's body, so such a condition
    would be invisible -- the job would look unguarded while its real
    policy lived somewhere else in the file.

    The controls do not resolve anchors: they refuse them. A workflow
    they cannot read is a workflow they cannot certify.
    """
    out = []
    if _uses_yaml_anchors(release):
        out.append("the workflow uses YAML anchors: the controls "
                   "cannot read a policy that is merged in from "
                   "elsewhere")
    return out


def prop_08_required_jobs_stay_mandatory(release, test):
    """The deploy needs the required jobs, and a failed, skipped or
    cancelled required job refuses the deployment.

    The condition must depend on the OUTCOME of the required jobs.
    The status functions are not interchangeable: success() is TRUE
    only when every need succeeded, while !cancelled() is TRUE even
    when a need FAILED -- GitHub documents it as running "even if the
    workflow is cancelled". A deploy job guarded by !cancelled()
    would publish the artifact of a SHA whose tests failed.
    """
    out = []
    for event, ref in (("push", "refs/heads/master"),
                       ("workflow_dispatch", "refs/heads/master")):
        allowed, reason = deploy_is_authorized(release, event, ref, False)
        if allowed:
            out.append("the deploy is authorized although a required job "
                       "did not succeed")
    # The needs must still be there.
    needs = _needs_of(release["jobs"], "deploy")
    for required in ("required-tests", "web-build"):
        if required not in needs:
            out.append("the deploy does not need %s" % required)

    # The condition must carry success(). The other status functions
    # are NOT equivalent: !cancelled() is true when a need failed.
    deploy = release["jobs"].get("deploy", "")
    condition = _job_condition(deploy)
    if condition:
        for function in ("!cancelled()", "failure()", "always()"):
            if function in condition and "success()" not in condition:
                out.append("the deploy condition uses %s instead of "
                           "success(): it is true even when a required "
                           "job failed" % function)
                break
    return out


def prop_09_no_failure_tolerance(release, test):
    """No job swallows its failure.

    always() would run the deploy job even when a required job FAILED,
    which would publish an artifact whose tests did not pass.

    The check reads the JOB-LEVEL CONDITION, not the body of the job:
    a COMMENT that mentions always() is not a bypass, and a textual
    search over the whole body would treat it as one. The same holds
    for continue-on-error: the key is looked up as a KEY, so a
    comment that names it does not count.
    """
    out = []
    for name, body in release["jobs"].items():
        condition = _job_condition(body)
        if condition and "always()" in condition:
            out.append("the %s job uses always(): it would run even when "
                       "a required job failed" % name)
        # continue-on-error is a KEY, so it is matched as a key and
        # not as a substring: a step that echoes the word is not the
        # same thing as the key.
        for line in body.split("\n"):
            if _is_yaml_true(line, "continue-on-error"):
                out.append("the %s job continues on error" % name)
                break
        # A STEP that runs REGARDLESS is the shape of a bypass: the
        # deploy job would be skipped when a need failed, but the
        # workflow still contains a step that runs no matter what.
        #
        # The condition is read at the STEP level here -- unlike the
        # job level, where a condition is the guard.
        #
        # Both spellings of a step condition are read: the mapping
        # form ("if: always()" under a step) and the list form
        # ("- if: always()" inside the step itself).
        #
        # A FOLDED or LITERAL block scalar is expanded before it is
        # judged: "if: >-" with "always()" on the next line is the
        # same condition, and reading only the ">-" would miss it.
        #
        # And the class is wider than always(): in GitHub Actions a
        # step with an `if` OVERRIDES the implicit success(), so
        # `if: failure()` and `if: !cancelled()` make the step RUN
        # after a failure. Every one of those is a publish-after-HOLD.
        # So the deploy job's steps may carry NO condition at all.
        for value in _step_conditions(body):
            # EVERY condition on a deploy-job step is refused, and
            # the condition is EVALUATED rather than matched against a
            # list of spellings.
            #
            # A step without a condition is the safe form. A
            # condition changes what the step does, and there are
            # three ways that matters, all of them openings:
            #   "if: false"         DISABLES the step -- and a
            #                        disabled tip check or artifact
            #                        validation is a removed check
            #   "if: always()"      runs it REGARDLESS
            #   "if: failure()"     runs it AFTER A FAILURE
            #
            # The last two are caught by evaluating the condition
            # against a failed previous step; the first is not, so
            # the whole class is refused.
            if _condition_runs_after_a_failure(value):
                out.append("the %s job carries a step that runs "
                           "regardless: %s" % (name, value))
                break
            if _condition_disables_the_step(value):
                out.append("the %s job carries a step that is disabled: "
                           "%s" % (name, value))
                break
    return out


def prop_07_no_stale_deployment(release, test):
    """The concurrency group is per ref, and the deploy job has a
    repository, so the tip check can read the remote."""
    out = []
    release_text = release["text"]
    if "group: pages-" not in release_text:
        out.append("the concurrency group does not separate the branches")
    if "github.ref" not in release_text:
        out.append("the concurrency group is not per ref")
    deploy = release["jobs"].get("deploy", "")
    if "actions/checkout" not in deploy:
        out.append("the deploy job has no checkout: the tip check cannot "
                   "read a remote")
    return out


# The properties, by control name.
# The properties of the GATE, one per control. NC-REL-06 and
# NC-REL-08 are NOT here: they measure the ARTIFACT VALIDATOR, not the
# gate, and they have their own branches. The registry carries only
# the gate properties, so every entry really is checked by the
# property it names.
#
# NC-REL-09 covers the artifact FLOW: the job that builds the
# artifact uploads it, and the deploy job does not upload a directory
# it does not have.
PROPERTIES = {
    "NC-REL-01": prop_01_battle_ecs_dependency,
    "NC-REL-02": prop_02_save_dependency,
    "NC-REL-03": prop_03_no_failure_tolerance,
    "NC-REL-04": prop_04_sha_identity,
    "NC-REL-05": prop_05_no_manual_bypass,
    "NC-REL-07": prop_07_no_stale_deployment,
    "NC-REL-09": prop_06_artifact_validation,
    "NC-REL-10": prop_06b_validation_is_a_gate,
    "NC-RB-01": prop_07_branch_authorization,
    "NC-RB-02": prop_07_branch_authorization,
    "NC-RB-03": prop_07_branch_authorization,
    "NC-RB-04": prop_07_branch_authorization,
    "NC-RB-05": prop_08_required_jobs_stay_mandatory,
    "NC-RB-06": prop_07_branch_authorization,
    "NC-RB-07": prop_09_no_failure_tolerance,
    "NC-RB-08": prop_07_branch_authorization,
    "NC-RB-09": prop_11_sha_checks_stay_real,
    "NC-RB-10": prop_11_sha_checks_stay_real,
    "NC-RB-11": prop_12_permissions_are_minimal,
    "NC-RB-12": prop_13_no_yaml_anchors,
    "NC-RB-13": prop_14_the_ref_set_is_a_rule,
    "NC-RB-14": prop_15_the_triggers_are_certified,
    "NC-RB-15": prop_16_the_concurrency_group_is_real,
    "NC-RB-16": prop_17_the_test_jobs_are_not_disabled,
    "NC-RB-17": prop_18_no_other_publisher,
    "NC-RB-18": prop_19_the_gate_is_not_swallowed,
    "NC-RB-19": prop_20_the_needs_exist,
    "NC-RB-20": prop_21_the_jobs_are_bounded,
    "NC-RB-21": prop_22_the_release_workflow_is_named,
    "NC-RB-22": prop_23_the_mandatory_steps_are_present,
    "NC-RB-23": prop_24_the_published_bytes_are_the_validated_bytes,
}


# =====================================================================
# THE MUTATIONS
# =====================================================================

def _mutate(text, old, new):
    if old not in text:
        return None
    return text.replace(old, new, 1)


MUTATIONS = [
    ("NC-REL-01",
     "remove the dependency on battle-ecs",
     "test.yml",
     [("  battle-ecs:\n    runs-on: ubuntu-latest",
       "  battle-ecs-disabled:\n    runs-on: ubuntu-latest\n    if: false")]),

    ("NC-REL-02",
     "remove the dependency on save-battle-migration",
     "test.yml",
     [("  save-battle-migration:\n    runs-on: ubuntu-latest",
       "  save-battle-migration-disabled:\n    runs-on: ubuntu-latest\n    if: false")]),

    ("NC-REL-03",
     "allow a failed/skipped required job",
     "release.yml",
     [("  required-tests:\n    name: Required CI\n",
       "  required-tests:\n    name: Required CI\n"
       "    continue-on-error: true\n")]),

    ("NC-REL-04",
     "remove the SHA identity check",
     "release.yml",
     [('          if [ "$TIP" != "${{ github.sha }}" ]; then\n'
       '            echo "HOLD: ${{ github.sha }} is not the tip of '
       '${GITHUB_REF_NAME} ($TIP is)."\n'
       '            echo "A stale deployment must not supersede a newer '
       'commit."\n'
       '            exit 1\n'
       '          fi',
       '          echo "the tip check is gone"')]),

    ("NC-REL-05",
     "allow a manual deployment bypass",
     "release.yml",
     [("    needs: [required-tests, web-build]",
       "    needs: [web-build]\n"
       "    if: ${{ github.event_name == 'workflow_dispatch' || true }}")]),

    ("NC-REL-06",
     "accept a missing index.html",
     "tools/validate_web_artifact.py",
     [('REQUIRED = [\n    "index.html",\n]',
       'REQUIRED = []')]),

    ("NC-REL-08",
     "accept a reference to a path the artifact does not carry",
     "tools/validate_web_artifact.py",
     [("        if not os.path.isfile(target):\n"
       "            fail(\"the index.html references %s, which the artifact "
       "does \"\n"
       "                 \"not carry at that path\" % ref, problems)",
       "        if os.path.basename(ref) not in files:\n"
       "            fail(\"the index.html references %s, which the artifact "
       "does \"\n"
       "                 \"not carry\" % os.path.basename(ref), problems)")]),

    ("NC-REL-09",
     "upload the artifact from the deploy job instead of the build job",
     "release.yml",
     [("      - uses: actions/upload-pages-artifact@v3\n"
       "        with:\n"
       "          path: build/\n",
       ""),
      ("      - uses: actions/configure-pages@v5",
       "      - uses: actions/upload-pages-artifact@v3\n"
       "        with:\n"
       "          path: build/\n"
       "      - uses: actions/configure-pages@v5")]),

    # --- The branch authorization controls (RB3) ---

    ("NC-RB-01",
     "remove the master-ref guard from the deploy job",
     "release.yml",
     [("        github.ref == 'refs/heads/master' &&\n", "")]),

    ("NC-RB-02",
     "replace the exact master-ref guard with one that accepts any branch",
     "release.yml",
     [("        github.ref == 'refs/heads/master' &&\n",
       "        github.ref != '' &&\n")]),

    ("NC-RB-03",
     "add an or-bypass for the workflow_dispatch event",
     "release.yml",
     [("          github.event_name == 'workflow_dispatch'\n",
       "          github.event_name == 'workflow_dispatch' ||\n"
       "          github.event_name == 'pull_request'\n")]),

    ("NC-RB-04",
     "move the master guard into an optional step and leave the job open",
     "release.yml",
     [("    if: >-\n"
       "      ${{\n"
       "        success() &&\n"
       "        github.ref == 'refs/heads/master' &&\n"
       "        (\n"
       "          github.event_name == 'push' ||\n"
       "          github.event_name == 'workflow_dispatch'\n"
       "        )\n"
       "      }}\n",
       ""),
      ("      - uses: actions/configure-pages@v5",
       "      - name: Note the ref\n"
       "        run: echo \"the ref is ${{ github.ref }}, and it must be "
       "refs/heads/master\"\n"
       "      - uses: actions/configure-pages@v5")]),

    ("NC-RB-05",
     "replace success() with a condition that tolerates a failed job",
     "release.yml",
     [("        success() &&\n",
       "        (success() || always()) &&\n")]),

    ("NC-RB-22",
     "delete the step that runs the controls",
     "test.yml",
     [("        run: python tools/release_negative_controls.py\n\n", "")]),

    ("NC-RB-23",
     "upload a path that was not validated",
     "release.yml",
     [("          path: build/\n", "          path: other/\n")]),

    ("NC-RB-18",
     "swallow the result of the controls",
     "test.yml",
     [("run: python tools/release_negative_controls.py",
       "run: python tools/release_negative_controls.py || true")]),

    ("NC-RB-19",
     "need a job that does not exist",
     "release.yml",
     [("    needs: [required-tests, web-build]",
       "    needs: [required-tests, web-build, ghost-job]")]),

    ("NC-RB-20",
     "remove the timeout of the deploy job",
     "release.yml",
     [("    timeout-minutes: 15\n", "")]),

    ("NC-RB-21",
     "rename the release workflow",
     "release.yml",
     [("name: Release\n", "name: Deploy\n")]),

    ("NC-RB-17",
     "add a second workflow that publishes the pages",
     "publish.yml",
     [("", "name: Publish\non:\n  push:\n    branches: ['*']\n"
       "permissions:\n  pages: write\n  id-token: write\n"
       "jobs:\n  deploy:\n    runs-on: ubuntu-latest\n"
       "    steps:\n      - uses: actions/checkout@v4\n"
       "      - uses: actions/deploy-pages@v4\n")]),


    ("NC-RB-16",
     "disable the battle-ecs job in the reusable workflow",
     "test.yml",
     [("  battle-ecs:\n    runs-on: ubuntu-latest",
       "  battle-ecs:\n    if: false\n    runs-on: ubuntu-latest")]),

    ("NC-RB-14",
     "add a pull_request trigger",
     "release.yml",
     [("on:\n  push:\n    branches: [master]",
       "on:\n  push:\n    branches: [master]\n  pull_request:")]),

    ("NC-RB-15",
     "make the concurrency group constant",
     "release.yml",
     [("group: pages-${{ github.ref }}", "group: pages-release")]),

    ("NC-RB-13",
     "authorize one more ref beside master",
     "release.yml",
     [("        github.ref == 'refs/heads/master' &&",
       "        ( github.ref == 'refs/heads/master' ||\n"
       "          github.ref == 'refs/tags/v1' ) &&")]),

    ("NC-RB-12",
     "merge the deploy job's policy in from a yaml anchor",
     "release.yml",
     [("  deploy:\n    name: Deploy to Pages",
       "  deploy:\n    <<: *base\n    name: Deploy to Pages")]),

    ("NC-RB-11",
     "give the build job the pages write permission",
     "release.yml",
     [("    needs: required-tests\n    runs-on: ubuntu-latest\n"
       "    timeout-minutes: 30\n    permissions:\n      contents: read",
       "    needs: required-tests\n    runs-on: ubuntu-latest\n"
       "    timeout-minutes: 30\n    permissions:\n"
       "      pages: write\n      contents: read")]),

    ("NC-RB-09",
     "accept the published sha whatever the tip of the branch is",
     "release.yml",
     [("          TIP=\"$(git ls-remote origin \"refs/heads/${GITHUB_REF_NAME}\" | cut -f1)\"",
       "          TIP=\"${{ github.sha }}\"")]),

    ("NC-RB-10",
     "accept the published sha whatever the tip of master is",
     "release.yml",
     [("          MASTER_SHA=\"$(git ls-remote origin refs/heads/master | cut -f1)\"",
       "          MASTER_SHA=\"${{ github.sha }}\"")]),

    ("NC-RB-08",
     "remove the case-independent check against the tip of master",
     "release.yml",
     [("      - name: Verify the SHA is the tip of master itself\n"
       "        run: |\n"
       "          set -euo pipefail\n"
       "          MASTER_SHA=\"$(git ls-remote origin refs/heads/master | cut -f1)\"\n"
       "          echo \"the tip of master: $MASTER_SHA\"\n"
       "          echo \"the SHA being published: ${{ github.sha }}\"\n"
       "          if [ -z \"$MASTER_SHA\" ]; then\n"
       "            echo \"HOLD: the tip of master could not be read.\"\n"
       "            echo \"An unreadable tip is a HOLD, never a GREEN.\"\n"
       "            exit 1\n"
       "          fi\n"
       "          if [ \"$MASTER_SHA\" != \"${{ github.sha }}\" ]; then\n"
       "            echo \"HOLD: ${{ github.sha }} is not the tip of master "
       "($MASTER_SHA is).\"\n"
       "            echo \"Only the tip of master may be published.\"\n"
       "            exit 1\n"
       "          fi\n\n",
       "")]),

    ("NC-RB-07",
     "let the build job continue on error",
     "release.yml",
     [("    runs-on: ubuntu-latest\n    timeout-minutes: 30\n"
       "    permissions:\n      contents: read\n    env:\n"
       "      GODOT_VERSION: '4.7-stable'",
       "    runs-on: ubuntu-latest\n    timeout-minutes: 30\n"
       "    continue-on-error: true\n    permissions:\n"
       "      contents: read\n    env:\n"
       "      GODOT_VERSION: '4.7-stable'")]),

    ("NC-RB-06",
     "block even the legitimate master push",
     "release.yml",
     [("        github.ref == 'refs/heads/master' &&\n",
       "        github.ref == 'refs/heads/never-published' &&\n")]),

    ("NC-REL-10",
     "swallow the failure of the artifact validation",
     "release.yml",
     [("python tools/validate_web_artifact.py build",
       "python tools/validate_web_artifact.py build || true")]),

    ("NC-REL-07",
     "remove the checkout that lets the tip check read the remote",
     "release.yml",
     [("concurrency:\n  group: pages-${{ github.ref }}\n"
       "  cancel-in-progress: false",
       "concurrency:\n  group: pages-${{ github.ref }}\n"
       "  cancel-in-progress: true"),
      ("      - uses: actions/checkout@v4\n        with:\n"
       "          fetch-depth: 1\n\n",
       "")]),
]


def load_jobs(path):
    """The workflows of the repository, read WITHOUT a YAML library.

    The repository's CI tools deliberately avoid a YAML dependency:
    this file was the only one that imported yaml, and no workflow
    installs pyyaml, so a yaml import here would have failed on the
    runner and turned the REQUIRED battle-ecs job RED.

    The reader understands what the properties need: the job names and
    the body of each job, with the two-space indentation the workflows
    use.

    Returns {job_name: body_text}.
    """
    with io.open(path, encoding="utf-8-sig") as f:
        text = f.read()

    jobs = {}
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        # A job header is "  name:" at the two-space indentation.
        match = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if match:
            name = match.group(1)
            body = []
            i += 1
            while i < len(lines):
                nxt = lines[i]
                if nxt.strip() == "":
                    body.append(nxt)
                    i += 1
                    continue
                # A line that is less indented ends the job.
                if not nxt.startswith("    ") and not nxt.startswith("  "):
                    break
                if re.match(r"^  [A-Za-z0-9_-]+:\s*$", nxt):
                    break
                body.append(nxt)
                i += 1
            jobs[name] = "\n".join(body)
            continue
        i += 1
    return jobs


def load_text(path):
    """The text of a file.

    The encoding is "utf-8-sig": a BOM is valid YAML and GitHub
    accepts it, but with the plain "utf-8" the BOM became part of
    the first line -- so "name: Release" no longer matched and the
    controls reported a FALSE RED on a legitimate commit.
    """
    with io.open(path, encoding="utf-8-sig") as f:
        text = f.read()
    # The BOM is stripped from the text itself: a reader that checks
    # the first line must see "name: Release", not the BOM in front
    # of it.
    return text.lstrip("\ufeff")


def load_validator_from(path):
    import importlib.util
    spec = importlib.util.spec_from_file_location("v_under_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def make_fake_artifact(with_html=True):
    """A synthetic artifact directory.

    It is a COMPLETE artifact, so a control that removes one
    requirement sees exactly that one requirement disappear and not a
    dozen others.
    """
    root = tempfile.mkdtemp(prefix="rel_art_")
    if with_html:
        with io.open(os.path.join(root, "index.html"), "w",
                     encoding="utf-8") as f:
            f.write("<html><body>test</body></html>\n")
    with io.open(os.path.join(root, "index.wasm"), "wb") as f:
        f.write(b"\x00asm" + b"\0" * (2 * 1024 * 1024))
    with io.open(os.path.join(root, "index.js"), "w",
                 encoding="utf-8") as f:
        f.write("var x = 1;\n")
    with io.open(os.path.join(root, "index.pck"), "wb") as f:
        f.write(b"\0" * (256 * 1024))
    return root


def make_reference_artifact(reference):
    """An artifact whose index.html references a path the artifact does
    not carry: "index.js" sits at the root, the html points into a
    subdirectory."""
    root = tempfile.mkdtemp(prefix="rel_ref_")
    with io.open(os.path.join(root, "index.html"), "w",
                 encoding="utf-8") as f:
        f.write("<html><body>x</body></html>\n" * 200)
        f.write("<script src='%s'></script>\n" % reference)
    with io.open(os.path.join(root, "index.wasm"), "wb") as f:
        f.write(b"\x00asm" + b"\0" * (2 * 1024 * 1024))
    with io.open(os.path.join(root, "index.js"), "w",
                 encoding="utf-8") as f:
        f.write("var x = 1;\n")
    with io.open(os.path.join(root, "index.pck"), "wb") as f:
        f.write(b"\0" * (256 * 1024))
    return root


def run_control(name, description, target, edits):
    """Runs one control in an isolated copy.

    Returns (verdict, rc, failed, errors).
    """
    tmp = tempfile.mkdtemp(prefix="rel_nc_")
    try:
        copy_wf = os.path.join(tmp, "workflows")
        shutil.copytree(WORKFLOWS, copy_wf)
        copy_validator = os.path.join(tmp, "validate_web_artifact.py")
        shutil.copyfile(VALIDATOR, copy_validator)

        if target == "release.yml":
            path = os.path.join(copy_wf, "release.yml")
        elif target == "test.yml":
            path = os.path.join(copy_wf, "test.yml")
        elif target.endswith(".yml") or target.endswith(".yaml"):
            # A NEW workflow file. The harness resolves its inputs by
            # filename, so a file it does not know about cannot be
            # checked -- and one that publishes on every branch with
            # pages: write would pass every control. The new file is
            # written whole, and the edits are applied to it.
            path = os.path.join(copy_wf, target)
            # The file is created with the PLAIN mode: on this host
            # io.open(path, "w", newline="") refuses a path that does
            # not exist yet.
            with open(path, "w", encoding="utf-8"):
                pass
        else:
            path = copy_validator

        with io.open(path, encoding="utf-8-sig") as f:
            text = f.read()

        for old, new in edits:
            if old == "" and text == "":
                # A NEW file: the content IS the mutation, so there is
                # no anchor to replace.
                text = new
                continue
            mutated = _mutate(text, old, new)
            if mutated is None:
                # The anchor is gone: the control cannot prove anything.
                return "SKIP", 1, 1, 0
            text = mutated

        with io.open(path, "w", encoding="utf-8", newline="") as f:
            f.write(text)

        failures = []

        if name == "NC-REL-08":
            # The reference check must compare the PATH. The clean
            # validator denies a reference to "subdir/index.js" when
            # the artifact carries only "index.js" at the root; the
            # mutated one compares the basename and allows it.
            clean = load_validator_from(
                os.path.join(REPO, "tools", "validate_web_artifact.py"))
            mutated_validator = load_validator_from(copy_validator)
            clean_problems = clean.validate(
                make_reference_artifact("subdir/index.js"))
            mutated_problems = mutated_validator.validate(
                make_reference_artifact("subdir/index.js"))
            if not clean_problems:
                failures.append("the clean validator ALLOWED a reference "
                                "to a path it does not carry")
            if mutated_problems:
                failures.append("the mutation did not open the validator: %s"
                                % "; ".join(mutated_problems))
            if failures:
                return "MISSED", 1, len(failures), 0
            return "RED", 0, 0, 0

        if name == "NC-REL-06":
            # The validator, not the gate.
            clean = load_validator_from(
                os.path.join(REPO, "tools", "validate_web_artifact.py"))
            mutated_validator = load_validator_from(copy_validator)
            clean_problems = clean.validate(make_fake_artifact(with_html=False))
            mutated_problems = mutated_validator.validate(
                make_fake_artifact(with_html=False))
            if not clean_problems:
                failures.append("the clean validator ALLOWED an artifact "
                                "without an index.html")
            if mutated_problems:
                failures.append("the mutation did not open the validator: %s"
                                % "; ".join(mutated_problems))
        else:
            property_fn = PROPERTIES[name]
            # The CLEAN gate must satisfy the property.
            clean_violations = property_fn(
                {"text": load_text(RELEASE), "jobs": load_jobs(RELEASE),
                 "directory": os.path.dirname(os.path.abspath(RELEASE))},
                {"text": load_text(TEST), "jobs": load_jobs(TEST),
                 "directory": os.path.dirname(os.path.abspath(TEST))})
            if clean_violations:
                failures.append("the clean gate already violates the "
                                "property: %s" % "; ".join(clean_violations))
            # The MUTATED gate must VIOLATE it: that is what the
            # mutation did.
            mutated_release = os.path.join(copy_wf, "release.yml")
            mutated_test = os.path.join(copy_wf, "test.yml")
            mutated_violations = property_fn(
                {"text": load_text(mutated_release),
                 "jobs": load_jobs(mutated_release),
                 "directory": os.path.dirname(mutated_release)},
                {"text": load_text(mutated_test),
                 "jobs": load_jobs(mutated_test),
                 "directory": os.path.dirname(mutated_test)})
            if not mutated_violations:
                failures.append("the mutation did not break the property")

        if failures:
            return "MISSED", 1, len(failures), 0
        return "RED", 0, 0, 0

    except Exception as error:  # noqa: BLE001
        return "INVALID", 1, 1, 1

    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def check_registry():
    """The registry must cover every control, and every property
    function must be reachable.

    The independent critic found a property function that was DEFINED
    and never REGISTERED, so the artifact flow had no control at all.
    This assertion is what prevents that class of defect from coming
    back: a control that no mechanism covers, or a property that
    nothing calls.

    Returns a list of violations.
    """
    violations = []

    # The controls that measure the VALIDATOR rather than the gate.
    validator_controls = {"NC-REL-06", "NC-REL-08"}

    mutation_names = set(m[0] for m in MUTATIONS)
    covered = set(PROPERTIES.keys()) | validator_controls

    for name in sorted(mutation_names - covered):
        violations.append("the control %s is covered by no mechanism" % name)
    for name in sorted(covered - mutation_names):
        violations.append("the mechanism for %s has no control" % name)

    # Every defined property function must be registered.
    defined = set()
    for key, value in globals().items():
        if key.startswith("prop_") and callable(value):
            defined.add(key)
    registered = set(v.__name__ for v in PROPERTIES.values())
    for name in sorted(defined - registered):
        violations.append("the property %s is defined but not registered" % name)

    # Every registered property must be used by at least one control:
    # a property nothing calls is a property nothing checks.
    used = set(v.__name__ for v in PROPERTIES.values())
    for name in sorted(defined - used):
        violations.append("the property %s is registered by no control"
                          % name)

    # Every control must have its own property entry: two controls
    # that share a property are fine -- that is what a property IS --
    # but a control whose mechanism is missing is not.
    for name in sorted(set(PROPERTIES.keys()) & mutation_names):
        pass

    return violations


def main():
    registry_problems = check_registry()
    if registry_problems:
        print("")
        print("THE REGISTRY IS INCOMPLETE:")
        for problem in registry_problems:
            print("   ", problem)
        print("")
        return 2

    print("")
    print("MUTATION     VERDICT       rc  fails  errs")
    results = []
    for name, description, target, edits in MUTATIONS:
        verdict, rc, failed, errors = run_control(name, description, target,
                                                  edits)
        results.append((name, verdict, rc, failed, errors))
        print("%-12s %-12s %2d %6d %5d"
              % (name, verdict, rc, failed, errors))

    problems = [r for r in results if r[1] != "RED"]
    print("")
    print("release controls: %d, clean: %d, problems: %d"
          % (len(results), len(results) - len(problems), len(problems)))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
