# frozen_string_literal: true

RSpec.shared_examples "canonical migrations" do
  let(:migrator) { River::Migrator.new(@driver) }

  it "tracks additional migration lines separately and enforces their main prerequisite" do
    other = River::Migrator.new(@driver, line: "test", migrations_path: File.join(__dir__, "support/migrations"))

    expect { other.migrate }.to raise_error(River::Error, /main to version 7/)
    migrator.migrate(target: 4)

    expect { other.status }.to raise_error(River::Error, /main to version 7/)
    migrator.migrate(target: 5)

    expect { other.status }.to raise_error(River::Error, /main to version 7/)
    migrator.migrate

    expect(other.migrate.map(&:version)).to eq([1])
    expect(other.status).to contain_exactly(have_attributes(applied: true, version: 1))
    expect(other.migrate(direction: :down).map(&:version)).to eq([1])
    expect(migrator.status).to all(have_attributes(applied: true))
  end

  it "validates migration options before applying any DDL" do
    expect { migrator.migrate(direction: :sideways) }.to raise_error(ArgumentError)
    [0, -1, "one"].each { |value| expect { migrator.migrate(steps: value) }.to raise_error(ArgumentError) }
    [-1, 8, "one"].each { |value| expect { migrator.migrate(target: value) }.to raise_error(ArgumentError) }

    expect { migrator.migrate(direction: :down, target: 1) }.to raise_error(ArgumentError, /opposite direction/)
    migrator.migrate

    expect { migrator.migrate(target: 1) }.to raise_error(ArgumentError, /opposite direction/)
  end

  it "bootstraps, upgrades legacy history, and is idempotent" do
    expect(migrator.status).to all(have_attributes(applied: false))
    expect(migrator.migrate(target: 4).map(&:version)).to eq([1, 2, 3, 4])
    expect(migrator.status.select(&:applied).map(&:version)).to eq([1, 2, 3, 4])
    expect(River::Migrator.new(@driver).migrate.map(&:version)).to eq([5, 6, 7])
    expect(migrator.status).to all(have_attributes(applied: true))
    expect(migrator.migrate).to eq([])
  end

  it "reverses migrations across the line-column boundary and can bootstrap again" do
    migrator.migrate

    expect(migrator.migrate(direction: :down).map(&:version)).to eq([7])
    expect(migrator.migrate(direction: :down, target: 4).map(&:version)).to eq([6, 5])
    expect(migrator.status.select(&:applied).map(&:version)).to eq([1, 2, 3, 4])
    expect(migrator.migrate(direction: :down, target: 0).map(&:version)).to eq([4, 3, 2, 1])
    expect(migrator.status).to all(have_attributes(applied: false))
    expect(migrator.migrate.length).to eq(7)
  end

  it "plans without writes and honors step limits" do
    expect(migrator.migrate(dry_run: true).length).to eq(7)
    expect(migrator.status).to all(have_attributes(applied: false))
    expect(migrator.migrate(steps: 2).map(&:version)).to eq([1, 2])
    expect(migrator.migrate(direction: :down, dry_run: true).map(&:version)).to eq([2])
    expect(migrator.status.count(&:applied)).to eq(2)
    expect(migrator.migrate(direction: :down, steps: 2).map(&:version)).to eq([2, 1])
  end

  it "preserves populated jobs through the SQLite JSONB migration and its reversal" do
    migrator.migrate(target: 6)
    @driver.migration_connection do |connection|
      sql = "INSERT INTO river_job (args, kind, max_attempts, metadata) VALUES ('{\"value\":42}', 'migration_test', 25, '{\"keep\":true}')"
      (@driver.migration_backend == :postgresql) ? connection.exec(sql) : connection.execute_batch(sql)
    end

    migrator.migrate

    expect(@driver.job_list).to contain_exactly(have_attributes(args: {"value" => 42}, kind: "migration_test", metadata: {"keep" => true}))
    migrator.migrate(direction: :down)
    migrator.migrate

    expect(@driver.job_list).to contain_exactly(have_attributes(args: {"value" => 42}, kind: "migration_test", metadata: {"keep" => true}))
  end

  it "rolls back failed DDL and history together while retaining earlier commits" do
    original = migrator.migrations
    broken = original.map do |migration|
      (migration.version == 2) ? River::Migrator::Migration.new(2, "broken", "CREATE TABLE migration_failure (value integer); SELECT * FROM no_such_migration_table;", "") : migration
    end

    migrator.instance_variable_set(:@migrations, broken)

    expect { migrator.migrate }.to raise_error(StandardError)
    expect(migrator.status.select(&:applied).map(&:version)).to eq([1])
    migrator.instance_variable_set(:@migrations, original)

    expect(migrator.migrate.length).to eq(6)
  end

  it "refuses to run inside an application transaction" do
    @driver.transaction do
      expect { migrator.migrate }.to raise_error(River::Error, /application transaction/)
    end
  end

  it "refuses unknown future or incomplete database histories" do
    migrator.migrate
    @driver.migration_connection do |connection|
      sql = "INSERT INTO river_migration (line, version) VALUES ('main', 8)"
      (@driver.migration_backend == :postgresql) ? connection.exec(sql) : connection.execute_batch(sql)
    end

    expect { migrator.migrate }.to raise_error(River::Error, /history/)
    @driver.migration_connection do |connection|
      sql = "DELETE FROM river_migration WHERE version IN (3, 8)"
      (@driver.migration_backend == :postgresql) ? connection.exec(sql) : connection.execute_batch(sql)
    end

    expect { migrator.status }.to raise_error(River::Error, /history/)
  end

  it "does not erase other migration lines when downgrading main" do
    migrator.migrate
    @driver.migration_connection do |connection|
      sql = "INSERT INTO river_migration (line, version) VALUES ('pro', 1)"
      (@driver.migration_backend == :postgresql) ? connection.exec(sql) : connection.execute_batch(sql)
    end

    expect { migrator.migrate(direction: :down, target: 4) }.to raise_error(River::Error, /non-main/)
    expect(migrator.status.select(&:applied).map(&:version)).to eq((1..7).to_a)
  end
end
