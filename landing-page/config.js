// Deployment settings for the landing page. Both values are public (they ship to every visitor),
// so never put a secret key here.
window.DUBBY_CONFIG = {
  // The Convex deployment's HTTP actions URL plus /waitlist, for example
  // "https://happy-otter-123.convex.site/waitlist". Signups land in the `waitlist` table.
  waitlistEndpoint: "https://stoic-platypus-829.convex.site/waitlist",

  // Optional Whop-native enrollment after the email spot is saved. This is the hackathon sandbox.
  whopWaitlistUrl: "https://sandbox.whop.com/checkout/plan_7MIKgOw8BsSEc",
  whopWaitlistSandbox: true,

  // The Whop plan ID for the founding price, for example "plan_XXXXXXXXXXXXX". When set, founding signups
  // pay in an embedded Whop checkout and the Convex /whop/webhook route marks them paid. Leave it empty
  // and founding signups are only recorded.
  whopPlanId: "",
};
