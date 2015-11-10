require 'spec_helper'

module Bosh::Director
  describe DeploymentPlan::JobMigrator do
    subject(:job_migrator) { described_class.new(deployment_plan, logger) }

    let(:etcd_job) do
      DeploymentPlan::Job.parse(deployment_plan, job_spec, Config.event_log, logger)
    end

    let(:etcd_job_spec) do
      spec = Bosh::Spec::Deployments.simple_job(name: 'etcd', instances: 4)
      spec['azs'] = ['z1', 'z2']
      spec
    end

    let(:deployment_manifest) do
      manifest = Bosh::Spec::Deployments.simple_manifest
      manifest['jobs'] = [etcd_job_spec]
      manifest
    end

    let(:job_spec) do
      deployment_manifest['jobs'].first
    end

    let(:cloud_config_manifest) do
      manifest = Bosh::Spec::Deployments.simple_cloud_config
      manifest['azs'] = [
        { 'name' => 'z1' },
        { 'name' => 'z2' },
      ]
      manifest['compilation']['az'] = 'z1'
      manifest['networks'].first['subnets'] = [
        {
          'range' => '192.168.1.0/24',
          'gateway' => '192.168.1.1',
          'dns' => ['192.168.1.1', '192.168.1.2'],
          'reserved' => [],
          'cloud_properties' => {},
          'az' => 'z1'
        },
        {
          'range' => '192.168.2.0/24',
          'gateway' => '192.168.2.1',
          'dns' => ['192.168.2.1', '192.168.2.2'],
          'reserved' => [],
          'cloud_properties' => {},
          'az' => 'z2'
        }
      ]
      manifest
    end

    let(:deployment_model) do
      cloud_config = Models::CloudConfig.make(manifest: cloud_config_manifest)
      Models::Deployment.make(
        name: deployment_manifest['name'],
        manifest: YAML.dump(deployment_manifest),
        cloud_config: cloud_config,
      )
    end

    let(:deployment_plan) do
      planner_factory = DeploymentPlan::PlannerFactory.create(logger)
      plan = planner_factory.create_from_model(deployment_model)
      plan
    end

    before do
      fake_locks
      prepare_deploy(deployment_manifest, cloud_config_manifest)
      allow(logger).to receive(:debug)
    end

    describe 'find_existing_instances' do
      context 'when job needs to be migrated from' do
        let(:etcd_job_spec) do
          job = Bosh::Spec::Deployments.simple_job(name: 'etcd', instances: 4)
          job['azs'] = ['z1', 'z2']
          job['migrated_from'] = [
            {'name' => 'etcd_z1', 'az' => 'z1'},
            {'name' => 'etcd_z2', 'az' => 'z2'},
          ]
          job
        end

        context 'when migrated_from job exists in previous deployment' do
          context 'when migrating_to job does not have existing instances' do
            let!(:migrated_job_instances) do
              instances = []
              instances << Models::Instance.make(job: 'etcd_z1', index: 0, deployment: deployment_model, vm: nil, uuid: 'uuid-1')
              instances << Models::Instance.make(job: 'etcd_z1', index: 1, deployment: deployment_model, vm: nil, uuid: 'uuid-2')
              instances << Models::Instance.make(job: 'etcd_z1', index: 2, deployment: deployment_model, vm: nil, uuid: 'uuid-3')
              instances << Models::Instance.make(job: 'etcd_z2', index: 0, deployment: deployment_model, vm: nil, uuid: 'uuid-4')
              instances << Models::Instance.make(job: 'etcd_z2', index: 1, deployment: deployment_model, vm: nil, uuid: 'uuid-5')
              instances
            end

            it 'returns existing instances of the migrated_from jobs' do
              migrated_instances = job_migrator.find_existing_instances(etcd_job)
              expect(migrated_instances).to contain_exactly(
                be_a_migrated_instance(migrated_job_instances[0], 'z1'),
                be_a_migrated_instance(migrated_job_instances[1], 'z1'),
                be_a_migrated_instance(migrated_job_instances[2], 'z1'),
                be_a_migrated_instance(migrated_job_instances[3], 'z2'),
                be_a_migrated_instance(migrated_job_instances[4], 'z2'),
              )
            end

            it 'logs the jobs being migrated' do
              expect(logger).to receive(:debug).with("Migrating job 'etcd_z1/uuid-1 (0)' to 'etcd/uuid-1 (0)'")
              expect(logger).to receive(:debug).with("Migrating job 'etcd_z1/uuid-2 (1)' to 'etcd/uuid-2 (1)'")
              expect(logger).to receive(:debug).with("Migrating job 'etcd_z1/uuid-3 (2)' to 'etcd/uuid-3 (2)'")
              expect(logger).to receive(:debug).with("Migrating job 'etcd_z2/uuid-4 (0)' to 'etcd/uuid-4 (0)'")
              expect(logger).to receive(:debug).with("Migrating job 'etcd_z2/uuid-5 (1)' to 'etcd/uuid-5 (1)'")
              job_migrator.find_existing_instances(etcd_job)
            end
          end

          context 'when migrating_to job already has existing instances' do
            let!(:existing_job_instances) do
              job_instances = []
              job_instances << Models::Instance.make(job: 'etcd', deployment: deployment_model, vm: nil, index: 0, bootstrap: true, uuid: 'uuid-7')
              job_instances << Models::Instance.make(job: 'etcd', deployment: deployment_model, vm: nil, index: 1, uuid: 'uuid-8')
              job_instances
            end

            let!(:migrated_job_instances) do
              instances = []
              instances << Models::Instance.make(job: 'etcd_z1', index: 0, deployment: deployment_model, vm: nil, uuid: 'uuid-1')
              instances << Models::Instance.make(job: 'etcd_z1', index: 1, deployment: deployment_model, vm: nil, uuid: 'uuid-2')
              instances << Models::Instance.make(job: 'etcd_z1', index: 2, deployment: deployment_model, vm: nil, uuid: 'uuid-3')
              instances << Models::Instance.make(job: 'etcd_z2', index: 0, deployment: deployment_model, vm: nil, uuid: 'uuid-4')
              instances << Models::Instance.make(job: 'etcd_z2', index: 1, deployment: deployment_model, vm: nil, uuid: 'uuid-5')
              instances << Models::Instance.make(job: 'etcd_z2', index: 2, deployment: deployment_model, vm: nil, uuid: 'uuid-6')

              instances
            end

            it 'return all existing instances from migrating_to job PLUS extra instances from migrated_from jobs' do
              migrated_instances = job_migrator.find_existing_instances(etcd_job)
              expect(migrated_instances).to contain_exactly(
                  be_a_migrated_instance(existing_job_instances[0], nil),
                  be_a_migrated_instance(existing_job_instances[1], nil),
                  be_a_migrated_instance(migrated_job_instances[0], 'z1'),
                  be_a_migrated_instance(migrated_job_instances[1], 'z1'),
                  be_a_migrated_instance(migrated_job_instances[2], 'z1'),
                  be_a_migrated_instance(migrated_job_instances[3], 'z2'),
                  be_a_migrated_instance(migrated_job_instances[4], 'z2'),
                  be_a_migrated_instance(migrated_job_instances[5], 'z2'),
                )
            end

            it 'logs the jobs being migrated' do
              expect(logger).to receive(:debug).with("Migrating job 'etcd_z1/uuid-1 (0)' to 'etcd/uuid-1 (0)'")
              expect(logger).to receive(:debug).with("Migrating job 'etcd_z1/uuid-2 (1)' to 'etcd/uuid-2 (1)'")
              expect(logger).to receive(:debug).with("Migrating job 'etcd_z1/uuid-3 (2)' to 'etcd/uuid-3 (2)'")
              expect(logger).to receive(:debug).with("Migrating job 'etcd_z2/uuid-4 (0)' to 'etcd/uuid-4 (0)'")
              expect(logger).to receive(:debug).with("Migrating job 'etcd_z2/uuid-5 (1)' to 'etcd/uuid-5 (1)'")
              expect(logger).to receive(:debug).with("Migrating job 'etcd_z2/uuid-6 (2)' to 'etcd/uuid-6 (2)'")
              job_migrator.find_existing_instances(etcd_job)
            end
          end
        end

        context 'when migrated_from job is still referenced in new deployment' do
          let(:deployment_manifest) do
            manifest = Bosh::Spec::Deployments.simple_manifest
            manifest['jobs'] = [
              etcd_job_spec,
              Bosh::Spec::Deployments.simple_job(name: 'etcd_z1').merge({'azs' => ['z1']}),
              Bosh::Spec::Deployments.simple_job(name: 'etcd_z2').merge({'azs' => ['z2']}),
            ]
            manifest
          end

          it 'raises an error' do
            expect {
              job_migrator.find_existing_instances(etcd_job)
            }.to raise_error(
                DeploymentInvalidMigratedFromJob,
                "Failed to migrate job 'etcd_z1' to 'etcd', deployment still contains it"
              )
          end
        end

        context 'when two jobs migrate from the same job' do
          let(:deployment_manifest) do
            manifest = Bosh::Spec::Deployments.simple_manifest
            another_job_spec = Bosh::Spec::Deployments.simple_job(name: 'another')
            another_job_spec['migrated_from'] = etcd_job_spec['migrated_from']
            another_job_spec['azs'] = etcd_job_spec['azs']
            manifest['jobs'] = [
              etcd_job_spec,
              another_job_spec
            ]
            manifest
          end

          it 'raises an error' do
            expect {
              job_migrator.find_existing_instances(etcd_job)
            }.to raise_error(
                DeploymentInvalidMigratedFromJob,
                "Failed to migrate job 'etcd_z1' to 'etcd', can only be used in one job to migrate"
              )
          end
        end

        context 'when migrated from section contains availability zone and instance models have different az' do
          before do
            Models::Instance.make(job: 'etcd_z1', index: 0, deployment: deployment_model, vm: nil, availability_zone: 'z10')
          end

          it 'raises an error' do
            expect {
              job_migrator.find_existing_instances(etcd_job)
            }.to raise_error(
                DeploymentInvalidMigratedFromJob,
                "Failed to migrate job 'etcd_z1' to 'etcd', 'etcd_z1' belongs to availability zone 'z10' and manifest specifies 'z1'"
              )
          end
        end

        context 'when migrated from section contains availability zone and instance models do not have az (legacy instances)' do
          before do
            Models::Instance.make(job: 'etcd_z1', index: 0, deployment: deployment_model, vm: nil, availability_zone: nil)
          end

          it 'updates instance az' do
            job_migrator.find_existing_instances(etcd_job)
            etcd_z1_instance = Models::Instance.find(job: 'etcd_z1', index: 0)
            expect(etcd_z1_instance.availability_zone).to eq('z1')
          end
        end

        context 'when migrated from section does not contain availability zone and instance models do not have az (legacy instances)' do
          let(:etcd_job_spec) do
            job = Bosh::Spec::Deployments.simple_job(name: 'etcd', instances: 4)
            job['migrated_from'] = [
              {'name' => 'etcd_z1'},
              {'name' => 'etcd_z2'},
            ]
            job['azs'] = ['z1', 'z2']
            job
          end
          before do
            Models::Instance.make(job: 'etcd_z1', index: 0, deployment: deployment_model, vm: nil, availability_zone: nil)
          end

          it 'raises an error' do
            expect {
              job_migrator.find_existing_instances(etcd_job)
            }.to raise_error(
                DeploymentInvalidMigratedFromJob,
                "Failed to migrate job 'etcd_z1' to 'etcd', availability zone of 'etcd_z1' is not specified"
              )
          end
        end
      end

      context 'when job does not need to be migrated' do
        let!(:existing_job_instances) do
          job_instances = []
          job_instances << Models::Instance.make(job: 'etcd', deployment: deployment_model, vm: nil)
          job_instances << Models::Instance.make(job: 'etcd', deployment: deployment_model, vm: nil)
          job_instances
        end

        it 'returns the list of existing job instances' do
          migrated_instances = job_migrator.find_existing_instances(etcd_job)
          expect(migrated_instances).to contain_exactly(
              be_a_migrated_instance(existing_job_instances[0], nil),
              be_a_migrated_instance(existing_job_instances[1], nil)
            )
        end
      end
    end
  end
end

RSpec::Matchers.define :be_a_migrated_instance do |expected, az|
  match do |actual|
    actual.reload == expected.reload && actual.availability_zone == az
  end
end

