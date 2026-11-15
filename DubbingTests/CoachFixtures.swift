/// The full Series example from the tutoring interface's progress section (synthetic acoustic fixtures,
/// not learner data), verbatim.
enum CoachFixtures {
    static let acousticSeries = #"""
{
  "locale": "en-US",
  "rubricVersion": "language-v1",
  "evaluator": {
    "provider": "synthetic",
    "modelVersion": null,
    "configVersion": "synthetic-v1",
    "measurement": "acoustic"
  },
  "pronunciationBasis": "acoustic",
  "unavailableMetrics": [],
  "volume": {
    "sessions": 2,
    "attempts": 5,
    "scorableAttempts": 4,
    "lines": 2,
    "practiceDays": 2,
    "speakingMs": 10000
  },
  "daily": [
    {
      "date": "2026-11-10",
      "firstScorable": {
        "languageOverall": {
          "value": 87,
          "samples": 1
        },
        "pronunciation": {
          "value": 85,
          "samples": 1
        },
        "wordAccuracy": {
          "value": 100,
          "samples": 1
        },
        "fluency": {
          "value": 70,
          "samples": 1
        },
        "timingFit": {
          "value": 90,
          "samples": 1
        }
      },
      "bestAttempt": {
        "languageOverall": {
          "value": 90,
          "samples": 1
        },
        "pronunciation": {
          "value": 86,
          "samples": 1
        },
        "wordAccuracy": {
          "value": 100,
          "samples": 1
        },
        "fluency": {
          "value": 80,
          "samples": 1
        },
        "timingFit": {
          "value": 90,
          "samples": 1
        }
      }
    },
    {
      "date": "2026-11-12",
      "firstScorable": {
        "languageOverall": {
          "value": 91.5,
          "samples": 2
        },
        "pronunciation": {
          "value": 88,
          "samples": 2
        },
        "wordAccuracy": {
          "value": 100,
          "samples": 2
        },
        "fluency": {
          "value": 86,
          "samples": 2
        },
        "timingFit": {
          "value": 90,
          "samples": 2
        }
      },
      "bestAttempt": {
        "languageOverall": {
          "value": 91.5,
          "samples": 2
        },
        "pronunciation": {
          "value": 88,
          "samples": 2
        },
        "wordAccuracy": {
          "value": 100,
          "samples": 2
        },
        "fluency": {
          "value": 86,
          "samples": 2
        },
        "timingFit": {
          "value": 90,
          "samples": 2
        }
      }
    }
  ],
  "skills": [
    {
      "metric": "languageOverall",
      "first": {
        "date": "2026-11-10",
        "value": 87
      },
      "latest": {
        "date": "2026-11-12",
        "value": 91.5
      },
      "change": 4.5,
      "direction": "steady"
    },
    {
      "metric": "pronunciation",
      "first": {
        "date": "2026-11-10",
        "value": 85
      },
      "latest": {
        "date": "2026-11-12",
        "value": 88
      },
      "change": 3,
      "direction": "steady"
    },
    {
      "metric": "wordAccuracy",
      "first": {
        "date": "2026-11-10",
        "value": 100
      },
      "latest": {
        "date": "2026-11-12",
        "value": 100
      },
      "change": 0,
      "direction": "steady"
    },
    {
      "metric": "fluency",
      "first": {
        "date": "2026-11-10",
        "value": 70
      },
      "latest": {
        "date": "2026-11-12",
        "value": 86
      },
      "change": 16,
      "direction": "improving"
    },
    {
      "metric": "timingFit",
      "first": {
        "date": "2026-11-10",
        "value": 90
      },
      "latest": {
        "date": "2026-11-12",
        "value": 90
      },
      "change": 0,
      "direction": "steady"
    }
  ],
  "lines": [
    {
      "sceneId": "scene_001",
      "lineId": "scene_001_line_02",
      "referenceVersion": 1,
      "referenceText": "You underestimate my power.",
      "attempts": 3,
      "latestAttemptId": "a4",
      "latestAssessmentId": "as4b",
      "latestRecordedAt": "2026-11-12T09:00:00-08:00",
      "latestStatus": "scored",
      "latestScores": {
        "languageOverall": 89,
        "pronunciation": 84,
        "wordAccuracy": 100,
        "fluency": 82,
        "timingFit": 90
      }
    },
    {
      "sceneId": "scene_001",
      "lineId": "scene_001_line_05",
      "referenceVersion": 1,
      "referenceText": "Hello there.",
      "attempts": 2,
      "latestAttemptId": "a5",
      "latestAssessmentId": "as5",
      "latestRecordedAt": "2026-11-12T23:30:00-08:00",
      "latestStatus": "scored",
      "latestScores": {
        "languageOverall": 94,
        "pronunciation": 92,
        "wordAccuracy": 100,
        "fluency": 90,
        "timingFit": 90
      }
    }
  ],
  "repeatedLines": [
    {
      "sceneId": "scene_001",
      "lineId": "scene_001_line_02",
      "referenceVersion": 1,
      "referenceText": "You underestimate my power.",
      "first": {
        "date": "2026-11-10",
        "value": 87,
        "attemptId": "a1",
        "assessmentId": "as1"
      },
      "latest": {
        "date": "2026-11-12",
        "value": 89,
        "attemptId": "a4",
        "assessmentId": "as4b"
      },
      "change": 2
    }
  ],
  "words": [
    {
      "word": "underestimate",
      "status": "persistent_weakness",
      "occurrences": 3,
      "issueCount": 3,
      "issueSessions": 2,
      "scriptIssueCount": 0,
      "pronunciationIssueCount": 3,
      "latestPronunciationScore": 61,
      "issueAttemptIds": [
        "a1",
        "a2",
        "a4"
      ],
      "issueAssessmentIds": [
        "as1",
        "as2",
        "as4b"
      ],
      "scriptIssueAssessmentIds": [],
      "pronunciationIssueAssessmentIds": [
        "as1",
        "as2",
        "as4b"
      ]
    }
  ],
  "guidance": {
    "summary": "You practised 2 lines across 2 sessions on 2 days, and 4 of 5 attempts could be scored. Averaged over the lines you practised each day, fluency rose from 70 to 86. On lines you repeated on different days, your language score improved on 0 of 1. Keep working on \"underestimate\".",
    "focusAreas": [
      {
        "kind": "word",
        "word": "underestimate",
        "status": "persistent_weakness",
        "issueCount": 3,
        "issueAttemptIds": [
          "a1",
          "a2",
          "a4"
        ]
      }
    ],
    "retryLines": [
      {
        "sceneId": "scene_001",
        "lineId": "scene_001_line_02",
        "referenceVersion": 1,
        "referenceText": "You underestimate my power.",
        "practiceWords": [
          "underestimate"
        ],
        "latestLanguageOverall": 89,
        "latestAttemptId": "a4",
        "latestAssessmentId": "as4b"
      }
    ],
    "newLines": []
  }
}
"""#
}
