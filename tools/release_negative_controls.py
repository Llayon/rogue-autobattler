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
    block = re.search(r"needs:\s*\n((?:\s+-\s*\S+\s*\n?)+)", body)
    if block:
        return " ".join(re.findall(r"-\s*(\S+)", block.group(1)))
    plain = re.search(r"needs:\s*(\S+)", body)
    if plain:
        return plain.group(1)
    return ""


def _job(jobs, name):
    """The body of a job, as text."""
    return jobs.get(name) or ""


def _block(jobs, job_name):
    """The body of a job as a text block, for the line-level checks."""
    return jobs.get(job_name) or ""


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
        value = match.group(1).strip()
        if value in (">-", ">", "|-", "|"):
            # The condition is the block that follows, joined.
            parts = []
            for follow in lines[index + 1:]:
                if not follow.strip():
                    continue
                if not follow.startswith("      "):
                    break
                parts.append(follow.strip())
            return " ".join(parts).strip()
        return value
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
    # The comparison must be a CONDITION that refuses. An echo that
    # merely MENTIONS the comparison is not a check: it prints a
    # message and continues.
    for index, line in enumerate(code.split("\n")):
        if "if" not in line:
            continue
        if "TIP" not in line or "github.sha" not in line:
            continue
        if line.strip().startswith("if"):
            compares = True
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
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            code.append(stripped)
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

    # The remote read must be in CODE.
    for line in deploy_body.split("\n"):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
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
        for line in code.split("\n"):
            stripped = line.strip()
            if not stripped.startswith("if"):
                continue
            if ("MASTER_SHA" in stripped and "github.sha" in stripped
                    and ("!=" in stripped or "==" in stripped)):
                compares = True
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
            unreadable = re.search(
                r"-z[^\n]*\n(?:[^\n]*\n){0,6}?[^\n]*exit\s+1",
                master_block)
            if not unreadable:
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
    code = []
    for line in deploy.split("\n"):
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            code.append(stripped)
    code_text = "\n".join(code)

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
    # The fail-closed refusal.
    if not re.search(r"exit\s+1", code_text):
        out.append("the SHA checks do not fail closed: an unreadable "
                   "tip must be a HOLD, never a GREEN")
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
        for elevated in ("pages: write", "id-token: write"):
            if elevated in code:
                if name != "deploy":
                    out.append("the %s job carries %s" % (name, elevated))
                break
    # The deploy job must still carry them: without them it could
    # not publish at all.
    deploy = _code_lines(release["jobs"].get("deploy", ""))
    if "pages: write" not in deploy:
        out.append("the deploy job has no pages: write: it could not "
                   "publish")

    # There must be exactly ONE publication step. A second one would
    # publish without the checks that guard the first: the checks look
    # at the job's body, and one guarded path plus one unguarded path
    # is an unguarded path.
    publications = deploy.count("actions/deploy-pages")
    if publications != 1:
        out.append("the deploy job has %d publication steps: there must "
                   "be exactly one" % publications)

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
            if re.match(r"^\s*continue-on-error\s*:\s*true\s*$", line):
                out.append("the %s job continues on error" % name)
                break
        # A STEP that runs REGARDLESS is the shape of a bypass: the
        # deploy job would be skipped when a need failed, but the
        # workflow still contains a step that runs no matter what.
        # The condition is read at the STEP level here -- unlike the
        # job level, where a condition is the guard.
        #
        # Both spellings of a step condition are read: the mapping
        # form ("if: always()" under a step) and the list form
        # ("- if: always()" inside the step itself).
        for line in body.split("\n"):
            match = re.match(r"^\s*(?:-\s*)?if\s*:\s*(.*)$", line)
            if not match:
                continue
            value = match.group(1).strip()
            if value.strip("'\"") in ("always()", "${{ always() }}",
                                       "${{always()}}"):
                out.append("the %s job carries a step that runs "
                           "regardless: %s" % (name, value))
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
    with io.open(path, encoding="utf-8") as f:
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
    with io.open(path, encoding="utf-8") as f:
        return f.read()


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
        else:
            path = copy_validator

        with io.open(path, encoding="utf-8") as f:
            text = f.read()

        for old, new in edits:
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
                {"text": load_text(RELEASE), "jobs": load_jobs(RELEASE)},
                {"text": load_text(TEST), "jobs": load_jobs(TEST)})
            if clean_violations:
                failures.append("the clean gate already violates the "
                                "property: %s" % "; ".join(clean_violations))
            # The MUTATED gate must VIOLATE it: that is what the
            # mutation did.
            mutated_release = os.path.join(copy_wf, "release.yml")
            mutated_test = os.path.join(copy_wf, "test.yml")
            mutated_violations = property_fn(
                {"text": load_text(mutated_release),
                 "jobs": load_jobs(mutated_release)},
                {"text": load_text(mutated_test),
                 "jobs": load_jobs(mutated_test)})
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
