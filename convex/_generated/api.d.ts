/* eslint-disable */
/**
 * Generated `api` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run `npx convex dev`.
 * @module
 */

import type * as assessment_align from "../assessment/align.js";
import type * as assessment_assess from "../assessment/assess.js";
import type * as assessment_azure from "../assessment/azure.js";
import type * as assessment_azureClient from "../assessment/azureClient.js";
import type * as assessment_index from "../assessment/index.js";
import type * as assessment_normalize from "../assessment/normalize.js";
import type * as assessment_types from "../assessment/types.js";
import type * as assessment_validate from "../assessment/validate.js";
import type * as assessments from "../assessments.js";
import type * as attempts from "../attempts.js";
import type * as coachCharacters from "../coachCharacters.js";
import type * as coachReply from "../coachReply.js";
import type * as crons from "../crons.js";
import type * as gradingContract from "../gradingContract.js";
import type * as history from "../history.js";
import type * as http from "../http.js";
import type * as integrations_contracts from "../integrations/contracts.js";
import type * as integrations_providers from "../integrations/providers.js";
import type * as lib_auth from "../lib/auth.js";
import type * as lib_catalog from "../lib/catalog.js";
import type * as lib_config from "../lib/config.js";
import type * as lib_env from "../lib/env.js";
import type * as lib_errors from "../lib/errors.js";
import type * as lib_ingest from "../lib/ingest.js";
import type * as lib_log from "../lib/log.js";
import type * as lib_openai from "../lib/openai.js";
import type * as lib_outcome from "../lib/outcome.js";
import type * as lib_timeZone from "../lib/timeZone.js";
import type * as lib_validators from "../lib/validators.js";
import type * as liveAvatar from "../liveAvatar.js";
import type * as media from "../media.js";
import type * as projects from "../projects.js";
import type * as scenes from "../scenes.js";
import type * as takes from "../takes.js";
import type * as tutoring from "../tutoring.js";
import type * as tutoringCoaching from "../tutoringCoaching.js";
import type * as tutoringExercise from "../tutoringExercise.js";
import type * as tutoringHttp from "../tutoringHttp.js";
import type * as tutoringMemory from "../tutoringMemory.js";
import type * as tutoringPreferences from "../tutoringPreferences.js";
import type * as tutoringProgress from "../tutoringProgress.js";
import type * as tutoringRecords from "../tutoringRecords.js";
import type * as tutoringRefs from "../tutoringRefs.js";
import type * as tutoringReply from "../tutoringReply.js";
import type * as tutoringTables from "../tutoringTables.js";
import type * as users from "../users.js";

import type {
  ApiFromModules,
  FilterApi,
  FunctionReference,
} from "convex/server";

declare const fullApi: ApiFromModules<{
  "assessment/align": typeof assessment_align;
  "assessment/assess": typeof assessment_assess;
  "assessment/azure": typeof assessment_azure;
  "assessment/azureClient": typeof assessment_azureClient;
  "assessment/index": typeof assessment_index;
  "assessment/normalize": typeof assessment_normalize;
  "assessment/types": typeof assessment_types;
  "assessment/validate": typeof assessment_validate;
  assessments: typeof assessments;
  attempts: typeof attempts;
  coachCharacters: typeof coachCharacters;
  coachReply: typeof coachReply;
  crons: typeof crons;
  gradingContract: typeof gradingContract;
  history: typeof history;
  http: typeof http;
  "integrations/contracts": typeof integrations_contracts;
  "integrations/providers": typeof integrations_providers;
  "lib/auth": typeof lib_auth;
  "lib/catalog": typeof lib_catalog;
  "lib/config": typeof lib_config;
  "lib/env": typeof lib_env;
  "lib/errors": typeof lib_errors;
  "lib/ingest": typeof lib_ingest;
  "lib/log": typeof lib_log;
  "lib/openai": typeof lib_openai;
  "lib/outcome": typeof lib_outcome;
  "lib/timeZone": typeof lib_timeZone;
  "lib/validators": typeof lib_validators;
  liveAvatar: typeof liveAvatar;
  media: typeof media;
  projects: typeof projects;
  scenes: typeof scenes;
  takes: typeof takes;
  tutoring: typeof tutoring;
  tutoringCoaching: typeof tutoringCoaching;
  tutoringExercise: typeof tutoringExercise;
  tutoringHttp: typeof tutoringHttp;
  tutoringMemory: typeof tutoringMemory;
  tutoringPreferences: typeof tutoringPreferences;
  tutoringProgress: typeof tutoringProgress;
  tutoringRecords: typeof tutoringRecords;
  tutoringRefs: typeof tutoringRefs;
  tutoringReply: typeof tutoringReply;
  tutoringTables: typeof tutoringTables;
  users: typeof users;
}>;

/**
 * A utility for referencing Convex functions in your app's public API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = api.myModule.myFunction;
 * ```
 */
export declare const api: FilterApi<
  typeof fullApi,
  FunctionReference<any, "public">
>;

/**
 * A utility for referencing Convex functions in your app's internal API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = internal.myModule.myFunction;
 * ```
 */
export declare const internal: FilterApi<
  typeof fullApi,
  FunctionReference<any, "internal">
>;

export declare const components: {};
