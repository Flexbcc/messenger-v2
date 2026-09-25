"""Soft assertions: record bugs and continue."""
from __future__ import annotations

from dataclasses import dataclass, field

from bugs import record_fail


@dataclass
class CheckResult:
    ok: bool
    title: str
    detail: str = ""


@dataclass
class ScenarioReport:
    name: str
    home_url: str
    passes: int = 0
    fails: int = 0
    checks: list[CheckResult] = field(default_factory=list)

    def expect(
        self,
        condition: bool,
        *,
        title: str,
        expected: str,
        observed: str,
        bot: str = "",
    ) -> bool:
        if condition:
            self.passes += 1
            self.checks.append(CheckResult(True, title, observed))
            print(f"  PASS  {title}")
            return True
        self.fails += 1
        self.checks.append(CheckResult(False, title, observed))
        print(f"  FAIL  {title}: {observed}")
        record_fail(
            scenario=self.name,
            title=title,
            expected=expected,
            observed=observed,
            home_url=self.home_url,
            bot=bot,
        )
        return False

    @property
    def status(self) -> str:
        if self.fails:
            return "FAIL"
        if self.passes:
            return "PASS"
        return "EMPTY"
