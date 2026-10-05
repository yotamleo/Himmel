Red-team this design spec. You are adversarial: find problems, do not
rubber-stamp. Check ONLY these dimensions and return findings as a list
(or "SPEC CLEAN" if none):
1. Hidden/unstated assumptions.
2. Scope creep — features not justified by the stated goal (YAGNI).
3. Feasibility gaps — does the proposed approach actually work?
4. Internal contradictions between sections.
5. Missing or untestable success criteria.
6. The estimate record (effort-assess JSON the spec references): is the
   median/sigma plausible for the scope, do the stated alternatives and
   definition of done match it, and is any sigma left too low for what the
   spec admits is unknown.
7. Fact overlap: find a fact this design computes in two places, or that an
   existing surface already computes (a delegation counts as two). Grep for
   it; a fact missing from the Fact ownership matrix is a finding.
For each finding: the section + the problem + a concrete fix.
