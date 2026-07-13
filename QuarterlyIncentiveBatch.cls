global class QuarterlyIncentiveBatch implements Database.Batchable<SObject>, Database.Stateful {

    global Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([SELECT Id, Lender__c FROM Loan__c WHERE Lender__c != null]);
    }

    global void execute(Database.BatchableContext bc, List<Loan__c> scope) {
        List<Incentive__c> toUpsert = new List<Incentive__c>();

        for (Loan__c loan : scope) {
            IncentiveCalculator.LenderConfig cfg = IncentiveCalculator.getLenderConfig(loan.Lender__c);
            List<Loan_Balance__c> balances = [SELECT End_of_Month_Balance__c, Month__c
                                              FROM Loan_Balance__c WHERE Loan__c = :loan.Id];
            Decimal earnings = IncentiveCalculator.calculateQuarterlyEarnings(balances, cfg);

            Incentive__c incentive = new Incentive__c(Loan__c = loan.Id, Quarterly_Earnings__c = earnings);
            List<Incentive__c> existing = [SELECT Id FROM Incentive__c WHERE Loan__c = :loan.Id LIMIT 1];
            if (!existing.isEmpty()) {
                incentive.Id = existing[0].Id;
            }
            toUpsert.add(incentive);
        }

        if (!toUpsert.isEmpty()) {
            upsert toUpsert;
        }
    }

    global void finish(Database.BatchableContext bc) {}
}